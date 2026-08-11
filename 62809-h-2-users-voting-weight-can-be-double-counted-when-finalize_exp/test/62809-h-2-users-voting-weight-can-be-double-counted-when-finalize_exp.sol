// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    Voter,
    VoterFixed,
    MiniToken
} from "./62809-h-2-users-voting-weight-can-be-double-counted-when-finalize.sol";

contract VoterDoubleCountTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant STAKE = 1000 ether;

    function test_exploit_votingWeightDoubleCountedAcrossBatches() public {
        Exploit e = new Exploit();
        e.run();

        // Real total sbfBMX stake behind the option is exactly STAKE...
        assertEq(e.realStake(), STAKE, "real stake");

        // ...but the buggy batched tally counted it twice.
        assertEq(e.buggyOptionWeight(), 2 * STAKE, "buggy option weight double-counted");
        assertEq(e.buggyOptionWeight(), 2 * e.realStake(), "buggy weight == 2x real stake");

        // Phantom (double-counted) weight credited to the attacker's chosen option.
        assertEq(e.phantomWeight(), STAKE, "phantom weight magnitude");

        // Harm recorded on the marker token to the VOTE-INTEGRITY sink.
        assertEq(e.sinkMarkerBalance(), STAKE, "sink marker records phantom weight");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), STAKE, "marker balance at sink == phantom weight");
    }

    function test_control_snapshotTally_countsStakeOnce() public {
        // Same attack sequence against the FIXED (snapshot) variant does NOT
        // double-count: the moved balance is ignored in batch 2.
        Exploit e = new Exploit();
        e.run();

        assertEq(e.fixedOptionWeight(), STAKE, "fixed counts stake once");
        assertLt(e.fixedOptionWeight(), e.buggyOptionWeight(), "fix strictly less than buggy");
        assertEq(e.buggyOptionWeight() - e.fixedOptionWeight(), STAKE, "the gap is exactly the phantom weight");
    }
}
