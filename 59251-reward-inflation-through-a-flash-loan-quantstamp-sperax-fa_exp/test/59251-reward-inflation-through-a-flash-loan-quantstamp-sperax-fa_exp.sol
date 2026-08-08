// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, FixedControl, MiniToken} from "./59251-reward-inflation-through-a-flash-loan-quantstamp-sperax-fa.sol";

contract Test_59251 is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_reward_inflation_flash_loan() public {
        Exploit e = new Exploit();
        e.run();

        uint256 attackerReward = e.attackerReward();
        uint256 honestReward = e.honestReward();
        uint256 fairShare = e.fairShare();
        uint256 stolen = e.stolen();

        MiniToken rewardToken = e.rewardToken();

        // Concrete inflated numbers: attacker holds only 1e18 of real stake (same
        // as the honest staker) yet claims the reward for a 1,000,001e18 snapshot.
        assertEq(honestReward, 1e18, "honest fair reward");
        assertEq(fairShare, 1e18, "attacker fair reward");
        assertEq(attackerReward, 1_000_001e18, "attacker inflated reward");
        assertEq(stolen, 1_000_000e18, "reward tokens stolen from the pool");

        // Attacker earns ~1,000,001x the honest staker for the same real stake.
        assertGt(attackerReward, honestReward * 1_000_000, "inflation multiplier");

        // REAL theft landed at the attacker EOA.
        assertEq(rewardToken.balanceOf(ATTACKER), 1_000_001e18, "stolen reward at attacker");

        emit log_named_decimal_uint("attacker reward", attackerReward, 18);
        emit log_named_decimal_uint("honest reward  ", honestReward, 18);
        emit log_named_decimal_uint("stolen         ", stolen, 18);
    }

    function test_control_fixed_blocks_same_block_cycle() public {
        FixedControl f = new FixedControl();

        // With the depositTs / same-block guard, the flash-loan withdraw reverts,
        // the loan cannot be repaid, and the whole attack reverts: no inflation.
        vm.expectRevert(bytes("same-block deposit+withdraw"));
        f.attack();

        // Attack reverted -> the attacker EOA never received any reward tokens.
        assertEq(ATTACKER.balance, 0, "no ETH theft");
    }
}
