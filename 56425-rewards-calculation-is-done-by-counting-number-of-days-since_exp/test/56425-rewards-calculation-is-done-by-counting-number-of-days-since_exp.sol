// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, RewardSeconds} from "./56425-rewards-calculation-is-done-by-counting-number-of-days-since.sol";

contract Finding56425Test is Test {
    function test_exploit_days_underpay() public {
        vm.warp(1_700_129_600);
        Exploit e = new Exploit();
        e.run();

        assertEq(e.elapsedSeconds(), 129_600, "elapsed");
        assertEq(e.daysHeld(), 1, "days");
        assertEq(e.paid(), 3 ether, "paid 3");
        assertEq(e.fair(), 4.5 ether, "fair 4.5");
        assertEq(e.shortfall(), 1.5 ether, "short 1.5");
        assertEq(e.balanceOf(address(this)), 3 ether, "holder minted 3");
        assertLt(e.paid(), e.fair(), "underpaid");
    }

    function test_control_seconds_pay_fair() public {
        vm.warp(1_700_129_600);
        RewardSeconds fixedReward = new RewardSeconds();
        fixedReward.run();

        assertEq(fixedReward.paid(), 4.5 ether, "control pays 4.5");
        assertEq(fixedReward.balanceOf(address(this)), 4.5 ether, "holder minted 4.5");
    }
}
