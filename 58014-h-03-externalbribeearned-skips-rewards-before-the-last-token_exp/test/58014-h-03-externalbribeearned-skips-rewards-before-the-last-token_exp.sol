// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    ExternalBribeFixed,
    Token
} from "./58014-h-03-externalbribeearned-skips-rewards-before-the-last-token.sol";

contract Finding58014Test is Test {
    function test_earned_skips_the_100() public {
        vm.warp(30 days);
        Exploit e = new Exploit();
        e.run();

        assertEq(e.shouldGet(), 100 ether, "user should get 100");
        assertEq(e.got(), 0, "earned returns 0");
        assertEq(e.paid(), 0, "claim pays 0");
        assertEq(e.leftInBribe(), 100 ether, "100 stays in the bribe");
        assertEq(e.reward().balanceOf(address(e)), 0, "user balance");
    }

    function test_same_skip_at_the_playground_timestamp() public {
        vm.warp(1_784_893_842);
        Exploit e = new Exploit();
        e.run();

        assertEq(e.shouldGet(), 100 ether, "stated amount");
        assertEq(e.got(), 0, "still skipped");
        assertEq(e.paid(), 0, "still unpaid");
    }

    function test_control_pays_the_100() public {
        vm.warp(30 days);
        Token reward = new Token();
        ExternalBribeFixed bribe = new ExternalBribeFixed(reward);
        uint256 epochNow = bribe.bribeStart(block.timestamp);
        uint256 prevEpoch = epochNow - bribe.DURATION();

        bribe.writeBalance(1, prevEpoch, 100 ether);
        bribe.writeBalance(1, epochNow, 100 ether);
        bribe.writeSupply(epochNow, 100 ether);
        bribe.notify(address(reward), prevEpoch, 100 ether);
        reward.mint(address(bribe), 100 ether);

        assertEq(bribe.earned(address(reward), 1), 100 ether, "fixed earned is 100");
        uint256 paid = bribe.getReward(address(reward), 1);
        assertEq(paid, 100 ether, "control pays the 100");
        assertEq(reward.balanceOf(address(this)), 100 ether, "user received 100");
        assertEq(reward.balanceOf(address(bribe)), 0, "bribe is empty");
    }
}
