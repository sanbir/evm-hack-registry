// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    MyStakingFixed
} from "./57534-fee-can-be-applied-multiple-times-to-same-rewards-in-mystaki.sol";

contract Finding57534Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_fee_applied_again_to_net_unclaimed() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.feeTaken(), 100 ether, "second fee");
        assertEq(e.userGot(), 900 ether, "user short 100");
        assertEq(e.extraFee(), 100 ether, "extra");
        assertEq(e.reward().balanceOf(SINK), 100 ether, "fee sink");
        assertEq(e.reward().balanceOf(address(e)), 900 ether, "user");
    }

    function test_control_net_unclaimed_is_not_feed_again() public {
        MiniToken reward = new MiniToken();
        MyStakingFixed staking = new MyStakingFixed(reward, SINK);
        reward.mint(address(staking), 1000 ether);
        staking.creditNet(address(this), 1000 ether);
        staking.claim();
        assertEq(staking.lastFee(), 0, "no second fee");
        assertEq(staking.lastPayout(), 1000 ether, "full net");
        assertEq(reward.balanceOf(address(this)), 1000 ether, "user whole");
        assertEq(reward.balanceOf(SINK), 0, "sink empty");
    }
}
