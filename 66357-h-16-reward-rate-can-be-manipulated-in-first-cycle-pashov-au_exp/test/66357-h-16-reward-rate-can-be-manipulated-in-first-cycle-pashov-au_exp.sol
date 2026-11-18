// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit, GaugeRewardsDistributorFixed, MockToken} from "./66357-h-16-reward-rate-can-be-manipulated-in-first-cycle-pashov-au.sol";
contract Finding66357Test is Test {
    function test_dust_notify_zeros_the_cycle() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.payout(), 1000);
        assertEq(e.stuck(), 1000e18);
        assertEq(e.token().balanceOf(address(e.dist())), 1000e18 + 1000);
    }
    function test_control_accrues_both_notifies() public {
        MockToken t = new MockToken("REG");
        GaugeRewardsDistributorFixed d = new GaugeRewardsDistributorFixed(t);
        t.mint(address(this), 1000e18 + 1000);
        t.approve(address(d), type(uint256).max);
        d.notifyRewardAmount(1000e18);
        d.notifyRewardAmount(1000);
        (uint256 rate,) = d.rewardData(address(t));
        assertEq(rate, 1000e18 / 1000 + 1);
    }
}
