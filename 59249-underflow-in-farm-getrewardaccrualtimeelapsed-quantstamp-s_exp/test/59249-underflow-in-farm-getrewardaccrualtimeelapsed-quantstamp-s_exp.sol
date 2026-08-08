// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, ExploitControl, MiniToken, Farm, FarmFixed} from "./59249-underflow-in-farm-getrewardaccrualtimeelapsed-quantstamp-s.sol";

contract Test_59249 is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant REWARD_POOL = 1_000_000 ether;

    function test_exploit_drains_all_reward_tokens() public {
        Exploit e = new Exploit();
        e.run();

        // Attacker claimed the entire reward pool.
        assertEq(e.stolen(), REWARD_POOL, "attacker should steal the whole reward pool");
        assertEq(e.farmRewardAfter(), 0, "farm reward balance should be drained to zero");

        // Real theft: ATTACKER now holds all the reward tokens.
        MiniToken reward = e.reward();
        assertEq(reward.balanceOf(ATTACKER), REWARD_POOL, "ATTACKER holds the stolen reward tokens");
        assertEq(reward.balanceOf(address(e.farm())), 0, "farm holds no reward tokens");
    }

    function test_control_fixed_farm_is_safe() public {
        ExploitControl c = new ExploitControl();
        c.run();

        // Same attack inputs, fixed accrual-time helper => nothing accrues, nothing is stolen.
        assertEq(c.stolen(), 0, "fixed farm should allocate zero rewards to the depositor");
        assertEq(c.farmRewardAfter(), REWARD_POOL, "fixed farm keeps its entire reward pool");

        MiniToken reward = c.reward();
        assertEq(reward.balanceOf(ATTACKER), 0, "ATTACKER steals nothing from the fixed farm");
        assertEq(reward.balanceOf(address(c.farm())), REWARD_POOL, "fixed farm retains all reward tokens");
    }
}
