// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    NFTStaking,
    NFTStakingFixed,
    MiniRewards,
    MiniToken
} from "./62873-h-01-incorrect-burn-reward-multiplier-reset-on-claim-reduces.sol";

contract BurnMultiplierResetTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_burnMultiplierReset_underpaysFrequentClaimer() public {
        // Push the clock far past the scenario duration so the backdated
        // timestamps used inside run() do not underflow.
        vm.warp(1000 days);

        Exploit e = new Exploit();
        e.run();

        // ── primary harm: two identical burn stakers over the same duration T ──
        // Staker A claims once at T; the single claim sees the full-duration
        // (capped) multiplier -> 864,000 reward tokens.
        assertEq(e.aBuggy(), 864_000 ether, "single-claim baseline");
        // Staker B claims once per day; every claim resets burnedAt, so the
        // multiplier is pinned at mult(1 day) -> only 30,024 reward tokens (~3.5%).
        assertEq(e.bBuggy(), 30_024 ether, "frequent-claim buggy total");
        assertLt(e.bBuggy(), e.aBuggy(), "frequent burn claimer is under-paid");

        // The lost burn rewards magnitude, recorded on the marker at the SINK.
        assertEq(e.shortfallBuggy(), 833_976 ether, "lost burn rewards (shortfall)");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 833_976 ether, "marker records lost rewards at SINK");

        // ── negative control: the recommended two-timestamp fix ──
        // A single claim is unaffected by the bug (no reset triggered).
        assertEq(e.aFixed(), e.aBuggy(), "single claim unaffected by the fix");
        // The fix restores the frequent claimer far above the buggy total.
        assertGt(e.bFixed(), e.bBuggy(), "fix restores frequent-claim accrual");
        // The reset-attributable recovery dominates the residual claim-early penalty.
        assertGt(e.recoveredByFix(), e.shortfallFixed(), "reset is the dominant loss cause");
        // The shortfall collapses (>3x smaller) once the multiplier reference stops resetting.
        assertLt(e.shortfallFixed() * 3, e.shortfallBuggy(), "shortfall collapses under the fix");

        emit log_named_uint("aBuggy  single-claim baseline    ", e.aBuggy());
        emit log_named_uint("bBuggy  frequent-claim (buggy)    ", e.bBuggy());
        emit log_named_uint("bFixed  frequent-claim (fixed)    ", e.bFixed());
        emit log_named_uint("shortfallBuggy  lost burn rewards ", e.shortfallBuggy());
        emit log_named_uint("shortfallFixed  residual penalty  ", e.shortfallFixed());
        emit log_named_uint("recoveredByFix  recovered by fix  ", e.recoveredByFix());
    }

    // Direct differential check against REAL elapsed time (vm.warp), independent
    // of the synthetic's seeding: the buggy contract resets the multiplier
    // reference on every claim, the fixed contract preserves burnStartAt.
    function test_control_fixed_preservesMultiplierReferenceAcrossClaims() public {
        vm.warp(1000 days);
        uint256 t0 = block.timestamp;

        // Buggy: claim, wait, claim. After the first claim burnedAt == now, so the
        // second claim's window is only the time since the first claim — the
        // multiplier reference is lost.
        NFTStaking bug = new NFTStaking(new MiniRewards());
        bug.seedBurnStake(1, address(this), uint64(t0 - 100 days));
        bug.claim(1); // resets burnedAt to t0
        (, , uint64 burnedAtAfter, , ) = bug.stakes(1);
        assertEq(uint256(burnedAtAfter), t0, "buggy resets multiplier reference to now");

        // Fixed: after a claim, burnStartAt is unchanged (still the original burn
        // start) — the multiplier keeps scaling with total burn duration.
        NFTStakingFixed fix = new NFTStakingFixed(new MiniRewards());
        fix.seedBurnStake(1, address(this), uint64(t0 - 100 days), uint64(t0 - 100 days));
        fix.claim(1);
        (, , uint64 burnStartAtAfter, ) = fix.stakes(1);
        assertEq(uint256(burnStartAtAfter), t0 - 100 days, "fix preserves burnStartAt across claims");
    }
}
