// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    CurveConvex2Token,
    CurveConvex2TokenFixed,
    CurveGauge,
    MiniToken
} from "./63525-inability-to-claim-rewards-from-the-curve-gauge-mixbytes-non.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Notional Finance (MixBytes) finding 63525 — Inability to Claim Rewards From
// the Curve Gauge. CurveConvex2Token._unstakeLpTokens() exits a pure-Curve
// position with ICurveGauge(CURVE_GAUGE).withdraw(poolClaim), leaving the
// Curve gauge's `_claim_rewards` flag at its default (False). Accrued CRV is
// never delivered on unstake and — with no reward manager for Curve strategies —
// stays locked in the gauge.
// ─────────────────────────────────────────────────────────────────────────────
contract InabilityToClaimCurveGaugeRewardsTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant REWARD = 1000 ether;

    function test_exploit_unstakeDoesNotDeliverGaugeRewards() public {
        Exploit e = new Exploit();
        e.run();

        // HARM: the verbatim _unstakeLpTokens delivered ZERO accrued CRV to the
        // strategy, while the full 1000 CRV is stranded in the gauge.
        assertEq(e.buggyStrategyCrv(), 0, "buggy strategy received CRV (should be 0)");
        assertEq(e.strandedInGauge(), REWARD, "accrued CRV not stranded in gauge");

        // The strategy has NO claim path: CRV really is stuck in the gauge and
        // the strategy holds none of it.
        MiniToken crv = MiniToken(e.crvAddr());
        assertEq(crv.balanceOf(e.strategyAddr()), 0, "strategy holds no CRV");
        assertEq(crv.balanceOf(e.gaugeAddr()), REWARD, "gauge still locks the 1000 CRV");

        // Undelivered/locked magnitude recorded on the LOCKED-CRV marker at SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), REWARD, "marker records locked CRV at SINK");
        assertEq(e.sinkMarkerBalance(), REWARD, "sink marker balance getter");
    }

    function test_control_fixedUnstakeDeliversGaugeRewards() public {
        // Negative control: the SAME flow through the fixed strategy, whose only
        // difference is withdraw(poolClaim, true), DELIVERS the accrued CRV.
        Exploit e = new Exploit();
        e.run();

        assertEq(e.fixedStrategyCrv(), REWARD, "fixed strategy did not receive full CRV");
        // The fix delivers strictly more than the vulnerable path — proving the
        // missing _claim_rewards flag is the exact cause of the reward loss.
        assertGt(e.fixedStrategyCrv(), e.buggyStrategyCrv(), "fix must out-deliver the bug");
    }
}
