// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, Staker, RewardCache, BGT, MiniToken, LossMarker} from "./55113-h-03-incorrect-boost-management-leads-to-staking-reward-loss.sol";

// Roots H-03 (finding 55113): Staker._redeemRewards / setValidator call
// rewardCache.dropBoost without a preceding rewardCache.queueDropBoost, so the BGT
// dropBoostQueue is empty and dropBoost always returns false. The boost is never
// dropped and the redeeming user's owed reward (1000e18) is silently lost / stuck.
contract Finding55113Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_missingQueueDropBoost_losesStakingReward() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("expected reward", e.expectedReward());
        emit log_named_uint("user received", e.userReceived());
        emit log_named_uint("boosted before", e.boostedBefore());
        emit log_named_uint("boosted after ", e.boostedAfter());
        emit log_named_uint("reward stuck in cache", e.rewardStuckInCache());
        emit log_named_uint("lost reward (sink)", e.lossMarker().balanceOf(SINK));

        // silent reward loss: user got nothing, boost never dropped, reward stuck
        assertEq(e.userReceived(), 0, "user should have received nothing (drop silently failed)");
        assertEq(e.expectedReward(), 1000 ether, "user was owed the full boosted reward");
        assertEq(e.boostedAfter(), e.boostedBefore(), "boost must not have been dropped");
        assertTrue(e.dropReturnedFalse(), "dropBoost must return false while queue is empty");
        assertEq(e.rewardStuckInCache(), 1000 ether, "owed reward is stuck in the BGT cache");
        assertEq(e.lossMarker().balanceOf(SINK), 1000 ether, "lost reward magnitude recorded at sink");
    }
}
