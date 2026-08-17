// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    VaultManagerV5,
    DyadXPv2,
    Dyad,
    MarkerToken
} from "./41690-h-03-updatexp-can-be-omitted-during-liquidation-pashov-audit.sol";

// DYAD H-03 (finding 41690): VaultManagerV5.liquidate burns part of a note's
// DYAD debt but only calls dyadXP.updateXP inside the `if (address(vault) ==
// KEROSENE_VAULT)` branch. When a liquidation seizes non-kerosene collateral,
// updateXP is omitted, so the note's DyadXPv2 snapshot keeps the pre-liquidation
// (higher) dyadMinted and keeps accruing XP at the inflated debt-bonus rate.
contract Finding41690Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_updateXPOmitted_staleDebtOverAccruesXP() public {
        // Exploit ctor deploys the system and performs the liquidation at t0.
        Exploit e = new Exploit();

        // One day passes after the liquidation; the buggy note keeps accruing
        // XP on its stale (higher) debt bonus.
        vm.warp(block.timestamp + 1 days);

        e.run();

        emit log_named_uint("stored dyadMinted (snapshot, stale)", e.storedDyadMinted());
        emit log_named_uint("actual debt (dyad.mintedDyad)", e.actualDebt());
        emit log_named_uint("balanceOfNote(id)  [stale bonus]", e.staleXP());
        emit log_named_uint("balanceOfNote(ref) [correct bonus]", e.correctXP());
        emit log_named_uint("excess XP over-accrued (marked at SINK)", e.excessXP());

        // The XP snapshot is provably out of sync: the note's debt was halved
        // by liquidation but the DyadXPv2 snapshot still records the old debt.
        assertEq(e.actualDebt(), 800e18, "debt should be halved to 800e18");
        assertEq(e.storedDyadMinted(), 1600e18, "snapshot still holds pre-liquidation 1600e18");
        assertTrue(e.storedDyadMinted() != e.actualDebt(), "snapshot must be stale");

        // Over one day the buggy note over-accrues XP versus an identical note
        // whose snapshot was correctly resynced to the post-burn debt.
        assertGt(e.staleXP(), e.correctXP(), "stale note must over-accrue XP");
        assertEq(e.excessXP(), e.staleXP() - e.correctXP(), "excess = stale - correct");
        assertGt(e.excessXP(), 0, "excess must be positive");

        // The over-credited XP (integrity loss) is quantified at SINK.
        assertEq(e.marker().balanceOf(SINK), e.excessXP(), "excess XP marked at SINK");
    }
}
