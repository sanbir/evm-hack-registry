// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {Exploit, Voter, BaseToken, Gauge} from "./58153-h-02-loss-of-claimable-rewards-upon-gauge-deactivation-pasho.sol";

// KittenSwap H-02 (finding 58153): Voter.killGauge sets claimable[_gauge] = 0,
// permanently destroying a gauge's already-accrued rewards. Two equally-weighted
// gauges each accrue 100e18; killing (then reviving) gauge A zeroes its share, so
// A receives 0 on distribution while identical gauge B receives its full 100e18,
// and the equivalent base tokens are stranded in the Voter forever.
contract Finding58153Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_killGauge_destroysClaimableRewards() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("accrued to gauge A before kill", e.accruedBeforeKill());
        emit log_named_uint("gauge A received after kill+revive", e.gaugeAReceived());
        emit log_named_uint("gauge B received (control)", e.gaugeBReceived());
        emit log_named_uint("stranded in Voter", e.strandedInVoter());
        emit log_named_uint("permanently lost rewards", e.lostRewards());

        assertEq(e.accruedBeforeKill(), 100 ether, "gauge A should have accrued 100e18");
        assertEq(e.gaugeAReceived(), 0, "killed+revived gauge A must receive nothing");
        assertEq(e.gaugeBReceived(), 100 ether, "identical gauge B receives its full share");
        assertEq(e.strandedInVoter(), 100 ether, "lost rewards stranded in Voter");
        assertEq(e.lostRewards(), 100 ether, "permanent loss = full accrued share");

        BaseToken base = e.base();
        assertEq(base.balanceOf(SINK), 100 ether, "loss marker minted to SINK");
    }
}
