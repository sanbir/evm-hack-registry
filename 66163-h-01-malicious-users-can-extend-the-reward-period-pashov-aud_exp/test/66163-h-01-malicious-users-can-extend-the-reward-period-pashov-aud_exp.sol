// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, RewardToken, GaugeRewardDistributorFixed} from
    "./66163-h-01-malicious-users-can-extend-the-reward-period-pashov-aud.sol";

contract Finding66163Test is Test {
    function test_exploit_tiny_notify_dilutes_and_extends() public {
        Exploit e = new Exploit();
        e.run();

        uint256 leftover = 6 days * 1e18;
        uint256 expectedRate = (1e18 + leftover) / 7 days;
        assertEq(e.newRate(), expectedRate, "rate");
        assertLt(e.newRate(), 1e18, "diluted");
        assertLt(e.windowPay(), 6 days * 1e18, "window");
        assertGt(e.newFinish(), e.oldFinish(), "extended");
        assertGt(e.obligation(), e.held(), "insolvent");
    }

    function test_control_rate_uses_remaining_time() public {
        RewardToken token = new RewardToken();
        GaugeRewardDistributorFixed fixedDist = new GaugeRewardDistributorFixed(token);
        uint256 finish = block.timestamp + 6 days;
        uint256 leftover = 6 days * 1e18;
        token.mint(address(this), leftover + 1e18);
        token.approve(address(fixedDist), leftover + 1e18);
        fixedDist.seedActiveCycle(1e18, finish);
        fixedDist.notifyRewardAmount(1e18);

        (uint256 rate, uint256 periodFinish) = fixedDist.rd();
        assertEq(periodFinish, finish, "finish unchanged");
        uint256 sum = leftover + 1e18;
        assertEq(rate, sum / 6 days, "rate over remaining");
        assertGt(rate, 1e18, "rate increased by the new token");
        uint256 obligation = rate * (periodFinish - block.timestamp);
        assertEq(obligation + (sum % 6 days), sum, "short only by division dust");
        assertLt(sum - obligation, 6 days, "dust under one second of value");
    }
}
