// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, PowerCheckpoint} from
    "./66162-c-08-incorrect-lock-duration-causes-extended-voting-power-re.sol";

contract Finding66162Test is Test {
    address constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_expired_min_lock_takes_half_the_reward() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.fixedPower(), 0, "actual duration is fully decayed");
        assertEq(e.attackerPower(), e.honestPower(), "buggy power equals the year lock");
        assertGt(e.attackerPower(), 0, "votes remain");
        assertEq(e.stolen(), 50e18, "half of 100 RWA");
        assertEq(e.token().balanceOf(SINK), 50e18, "sink");
        assertEq(e.token().balanceOf(e.checkpoint().HONEST()), 50e18, "honest only got half");
    }

    function test_control_actual_duration_gives_the_reward_to_the_year_lock() public {
        Token token = new Token();
        PowerCheckpoint checkpoint = new PowerCheckpoint(token);
        address attacker = address(0xA11CE);
        checkpoint.lockTokens(attacker, 365e18, checkpoint.MIN_LOCK());
        checkpoint.lockTokens(checkpoint.HONEST(), 365e18, checkpoint.MAX_LOCK());

        uint256 when = checkpoint.MIN_LOCK();
        assertEq(checkpoint.getVotingPowerFixed(attacker, when), 0, "min lock expired");
        assertGt(checkpoint.getVotingPowerFixed(checkpoint.HONEST(), when), 0, "year lock still voting");

        uint256 buggy = checkpoint.getVotingPowerAtBlock(attacker, when);
        assertGt(buggy, 0, "buggy path still nonzero, which is the bug");
    }
}
