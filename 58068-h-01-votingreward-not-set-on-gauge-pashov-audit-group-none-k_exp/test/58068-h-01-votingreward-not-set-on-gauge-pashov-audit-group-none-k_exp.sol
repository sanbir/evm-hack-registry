// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, GaugeFixed, Reward, MockToken} from "./58068-h-01-votingreward-not-set-on-gauge-pashov-audit-group-none-k.sol";

contract UnsetRewardTest is Test {
    function test_exploit_claimPaysZeroWhileFeesSitInTheGauge() public {
        Exploit e = new Exploit();
        e.run();

        assertFalse(e.forwarded(), "notify reverted");
        assertEq(e.claimed(), 0, "claim is 0");
        assertEq(e.stuck(), 1000 ether, "1000 sits in the gauge");
        assertEq(e.token().balanceOf(address(e.gauge())), 1000 ether, "balance");
        assertEq(address(e.gauge().votingReward()), address(0), "unset");
    }

    function test_control_setRewardPays1000() public {
        MockToken token = new MockToken();
        Reward reward = new Reward(address(this));
        GaugeFixed gauge = new GaugeFixed(address(token), address(reward));
        gauge.pullFees(1000 ether);
        gauge.forwardFees();

        assertEq(token.balanceOf(address(this)), 1000 ether, "depositor paid");
        assertEq(token.balanceOf(address(gauge)), 0, "gauge emptied");
    }
}
