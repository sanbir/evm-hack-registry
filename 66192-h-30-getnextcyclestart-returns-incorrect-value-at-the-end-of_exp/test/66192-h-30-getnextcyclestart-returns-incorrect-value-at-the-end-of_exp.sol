// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, GaugeRewardsDistributor} from
    "./66192-h-30-getnextcyclestart-returns-incorrect-value-at-the-end-of.sol";

contract Finding66192Test is Test {
    uint256 internal constant TS = 1_784_893_842;

    function test_exploit_boundary_pays_one_staker_the_whole_week() public {
        vm.warp(TS);
        Exploit e = new Exploit();
        e.run();

        uint256 week = 7 days * 1e12;
        assertEq(e.gauge().leftover(), 2 * week, "leftover booked for two weeks");
        assertEq(e.gauge().periodFinish(), TS + 14 days, "periodFinish is two durations out");
        assertEq(e.token().balanceOf(address(e)), week, "staker A received the entire funded week");
        assertEq(e.gauge().paidB(), 0, "staker B was paid 0");
        assertEq(e.token().balanceOf(address(e.stakerB())), 0, "staker B tokens");
        assertEq(e.token().balanceOf(address(e.gauge())), 0, "gauge is empty");
    }

    function test_control_fixed_helper_returns_the_boundary() public {
        vm.warp(TS);
        Exploit e = new Exploit();
        e.gauge().syncBoundary(address(e), address(e.stakerB()));
        assertEq(e.gauge().getNextCycleStart(), TS + 7 days, "buggy helper skips a week");
        assertEq(e.gauge().getNextCycleStartFixed(), TS, "fixed helper returns the boundary");
    }
}
