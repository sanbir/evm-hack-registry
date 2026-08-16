// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, Gauge, Pair, MiniToken} from "./58208-h-01-votingreward-not-set-on-gauge-pashov-audit-group-none-k.sol";

contract VotingRewardNotSetTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_votingReward_not_set_bricks_fee_distribution() public {
        Exploit e = new Exploit();
        e.run();

        // The verbatim vulnerable line reverted (votingReward unset -> address(0)).
        assertTrue(e.notifyReverted(), "notifyRewardAmount should revert");

        // The swap fees are permanently stuck in the pair (never distributed).
        assertEq(e.stuckFees(), e.FEES(), "fees should remain stuck in the pair");
        assertEq(e.token0().balanceOf(address(e.pair())), e.FEES(), "pair still holds fees");

        // DoS harm magnitude recorded at the sink.
        assertEq(e.marker().balanceOf(SINK), e.FEES(), "harm magnitude recorded at sink");
    }
}
