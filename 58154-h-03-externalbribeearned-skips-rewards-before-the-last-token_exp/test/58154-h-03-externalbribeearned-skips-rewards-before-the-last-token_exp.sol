// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {Exploit, ExternalBribe, RewardToken} from "./58154-h-03-externalbribeearned-skips-rewards-before-the-last-token.sol";

// KittenSwap H-03 (finding 58154): ExternalBribe.earned loops to `_endIndex - 1`,
// so the reward computed for the checkpoint at index `_endIndex - 1` (a full
// epoch) is never added. A voter with equal weight across 3 identically-bribed
// epochs is undercounted by exactly one epoch (100e18) vs a correct loop.
contract Finding58154Test is Test {
    function test_exploit_earnedSkipsMiddleEpoch() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("buggy earned()", e.buggyEarned());
        emit log_named_uint("correct earned()", e.correctEarned());
        emit log_named_uint("skipped (lost) reward", e.skippedReward());
        emit log_named_uint("real bribes stranded in ExternalBribe", e.strandedInBribe());

        // the vulnerable accounting reports strictly less than a correct loop
        assertLt(e.buggyEarned(), e.correctEarned(), "earned() must undercount");
        // and the shortfall is exactly one full epoch's bribe
        assertEq(e.skippedReward(), 100 ether, "exactly one epoch (100e18) is skipped");
        // the skipped reward is backed by real bribe tokens sitting in the contract
        assertGe(e.strandedInBribe(), e.skippedReward(), "loss backed by real tokens");
        // quantified permanent loss marked at the sink
        assertEq(
            e.reward().balanceOf(0x000000000000000000000000000000000000D00d),
            e.skippedReward(),
            "loss marker at SINK"
        );
    }
}
