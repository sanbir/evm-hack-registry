// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    YuzuILP,
    YuzuILPFixed,
    MiniToken,
    User,
    Math
} from "./62758-h-03-fee-avoidance-possible-by-uncollected-fees-in-pool-acco.sol";

// YuzuUSD (Ouroboros) H-03 — Fee avoidance possible by uncollected fees in pool
// accounting. Verbatim YuzuILP._withdraw fee/poolSize/conversion math reduced to
// a single-vault synthetic. Real source:
// github.com/Telos-Consilium/ouroboros-contracts @ 6dab29807b9e (audited/pre-fix).
contract FeeAvoidanceUncollectedPoolFeesTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant FIXED_TREASURY = 0x00000000000000000000000000000000fEE00001;

    uint256 internal constant DEPOSIT = 100 ether;

    function test_exploit_redeemFeeLeftInPool_enablesFeeAvoidance() public {
        Exploit e = new Exploit();
        e.run();

        // ── First redeemer pays the full ~10% fee (of the net payout). ──
        // gross = 100e18, fee = ceil(100e18/11), net = 100e18 - fee.
        assertEq(e.buggyNetA(), 90909090909090909090, "userA net payout (full fee)");

        // ── Second redeemer recovers a WINDFALL for an identical deposit and
        //    identical nominal fee, because userA's fee stayed in poolSize and
        //    inflated the remaining share price. ──
        assertEq(e.buggyNetB(), 99173553719008264463, "userB net payout (inflated)");
        assertGt(e.buggyNetB(), e.buggyNetA(), "second redeemer out-earns the first");

        // Effective fee (relative to the identical 100 yzUSD deposit):
        //   userA ~9.09 yzUSD (9.09%), userB ~0.83 yzUSD (0.83%).
        uint256 effFeeA = DEPOSIT - e.buggyNetA();
        uint256 effFeeB = DEPOSIT - e.buggyNetB();
        assertEq(effFeeA, 9090909090909090910, "userA effective fee");
        assertEq(effFeeB, 826446280991735537, "userB effective fee");
        // userB's effective fee is more than 10x smaller than userA's.
        assertLt(effFeeB * 10, effFeeA, "second redeemer's fee shrinks toward zero");

        // ── Harm marker: the escaped redeem fee (userB's windfall over userA)
        //    is recorded on the marker minted to the SINK. ──
        assertEq(e.escapedFees(), 8264462809917355373, "escaped fee magnitude (~8.26 yzUSD)");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), e.escapedFees(), "marker records escaped fee at SINK");
        assertEq(marker.symbol(), "LOST-YZUSD", "marker denominated in escaped yzUSD fees");

        // The protocol never collected the fee: the buggy vault only strands the
        // leftover (~feeB), far below the nominal two-redemption fee take.
        assertEq(e.buggyVaultLeftover(), 9917355371900826447, "buggy vault leftover (uncollected)");
    }

    function test_control_fixedVault_symmetricFeesAndFullCollection() public {
        Exploit e = new Exploit();
        e.run();

        // Fixed vault removes the FULL gross from poolSize and forwards the fee
        // to the treasury: both redeemers pay the SAME full fee, no windfall.
        assertEq(e.fixedNetA(), 90909090909090909090, "fixedNetA full fee");
        assertEq(e.fixedNetB(), 90909090909090909090, "fixedNetB full fee");
        assertEq(e.fixedNetA(), e.fixedNetB(), "fixed control is symmetric");

        // Treasury collects the full nominal fee of BOTH redemptions
        // (~2 x 9.09 = ~18.18 yzUSD) — the amount the buggy path forfeits.
        assertEq(e.fixedTreasuryBalance(), 18181818181818181820, "fixed treasury collects both fees");

        // The buggy path leaves the second redeemer strictly better off than the
        // fixed (correct) path — proving the harm is caused by the bug.
        assertGt(e.buggyNetB(), e.fixedNetB(), "bug lets second redeemer avoid the fee");

        // Escaped fee == fixed treasury take minus what the buggy vault stranded.
        assertEq(
            e.escapedFees(),
            e.fixedTreasuryBalance() - e.buggyVaultLeftover(),
            "escaped == fixed-collection shortfall"
        );
    }
}
