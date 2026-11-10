// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    RewardToken,
    Rewards,
    UptimeMessage,
    UptimeTracker,
    UptimeTrackerFixed
} from "./61240-inaccurate-uptime-distribution-in-uptimetrackercomputevalida.sol";

contract Finding61240Test is Test {
    address internal constant VALIDATOR = 0x1111111111111111111111111111111111111111;

    function test_even_split_pays_500_instead_of_900() public {
        vm.warp(1_000_000);
        Exploit e = new Exploit();
        vm.prank(VALIDATOR);
        e.run();

        assertEq(e.paid(), 500 ether, "paid");
        assertEq(e.fair(), 900 ether, "fair");
        assertEq(e.tracker().uptimeOf(e.lowEpoch()), 50, "inactive epoch");
        assertEq(e.tracker().uptimeOf(e.highEpoch()), 50, "active epoch");
        assertEq(e.token().balanceOf(VALIDATOR), 500 ether, "validator");
        assertEq(e.token().balanceOf(address(e.rewards())), 400 ether, "shortfall stays");

        console2.log("paid", e.paid());
        console2.log("fair", e.fair());
        console2.log("low uptime", e.tracker().uptimeOf(e.lowEpoch()));
        console2.log("high uptime", e.tracker().uptimeOf(e.highEpoch()));
    }

    function test_control_active_epoch_pays_the_fair_900() public {
        vm.warp(1_000_000);
        uint256 nowTs = block.timestamp < 200 ? 200 : block.timestamp;
        uint48 currentEpoch = uint48(nowTs / 100);
        uint48 lowEpoch = currentEpoch - 2;
        uint48 highEpoch = currentEpoch - 1;

        RewardToken token = new RewardToken();
        UptimeMessage message = new UptimeMessage();
        UptimeTrackerFixed tracker = new UptimeTrackerFixed(message, highEpoch);
        Rewards rewards = new Rewards(token, UptimeTracker(address(tracker)));
        tracker.seed(uint256(lowEpoch) * 100);
        rewards.setRate(lowEpoch, 1 ether);
        rewards.setRate(highEpoch, 9 ether);
        token.mint(address(rewards), 900 ether);
        tracker.computeValidatorUptime();

        vm.prank(VALIDATOR);
        uint256 paid = rewards.payout(lowEpoch, 2);

        assertEq(tracker.uptimeOf(lowEpoch), 0, "inactive epoch gets nothing");
        assertEq(tracker.uptimeOf(highEpoch), 100, "active epoch gets the full 100 seconds");
        assertEq(paid, 900 ether, "fair payout");
        assertEq(token.balanceOf(VALIDATOR), 900 ether, "validator");
        assertEq(token.balanceOf(address(rewards)), 0, "no shortfall");

        console2.log("control paid", paid);
        console2.log("control high uptime", tracker.uptimeOf(highEpoch));
    }
}
