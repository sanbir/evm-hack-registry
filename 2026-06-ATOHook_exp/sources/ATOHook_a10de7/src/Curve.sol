// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
    跡 (ato) jp. “a trace — the mark left behind” · a curve that retraces

    https://at0.io
    https://x.com/at0dev

        ato  ·  bonding curve

    21m ┤                                                             ∞  800x
        │                               ┊                    ╭────────╯
        │                               ┊            ╭───────╯      ╭╯
        │                               ┊     ╭──────╯       ╭╮    ╭╯
    15m ┤                              ╭◯─────╯             ╭╯│   ╭╯     600x
        │                        ╭─────╯┊                  ╭╯ │ ╭─╯
        │                   ╭────╯      ┊           ╭╮   ╭─╯  │╭╯
    10m ┤              ╭────╯           ┊         ╭─╯│  ╭╯    ╰╯         400x
        │          ╭───╯                ┊        ╭╯  │╭─╯
        │       ╭──╯                    ┊ ╭─╮  ╭─╯   ╰╯
        │     ╭─╯                  ╭╮   ◯─╯ │╭─╯
     5m ┤   ╭─╯                 ╭──╯│ ╭─╯   ╰╯                           200x
        │ ╭─╯            ╭─╮  ╭─╯   ╰─╯ ┊
        │ │      ╭╮  ╭───╯ ╰──╯         ┊
        │●╯──────╯╰──╯
      0 └──────────────────┴───────────────────┴──────────────────┴───── Ξ
                          500                 1000               1500

        ╭─ mint curve      ╭╮ price (sawtooth)      ┊◯ deprecation

    ato is an ERC-20 minted along a bonding curve embedded in a Uniswap v4 hook.
    The hook is the sole counterparty — every buy mints along a forward curve and
    every sell redeems along its inverse, paid from a reserve the hook holds.
    Supply approaches a hard asymptote of 21,000,000 and never reaches it;
    price rises exponentially with cumulative ETH and retraces ~50% at each halving
    of remaining supply — the trace the curve leaves behind.

    The retrace is not incidental: it is the engine that makes mining yield and
    LP volume work.
*/

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title  Curve — ATO all-below sawtooth bonding-curve math
/// @notice Stateless pure library. Implements the all-below (mode 3) sawtooth:
///         mint rides below the Sato reference and recovers up to it at each halving;
///         in Phase 2 redemption follows a smooth floor (1−D)·Sato.
/// @dev    Every cycle is algebraically a plain `p = sc/(cap−q)` curve with two
///         swapped constants (§1/§3). Positions are token supplies in wad (1e18).
///         ETH is wei. Prices are returned scaled ×1e18 (wei per token × 1e18).
///         Rounding favors the reserve everywhere (§7): mint tokens ↓, redeem ETH ↓.
library Curve {
    /*//////////////////////////////////////////////////////////////
                          LOCKED CONSTANTS (§2)
    //////////////////////////////////////////////////////////////*/

    /// @dev Hard cap / asymptote.
    uint256 internal constant K = 21_000_000e18;
    /// @dev Base scale (cycle 0). = 3·S_STAR. Anchored so reserve@C5 ≈ 800 ETH.
    uint256 internal constant S = 314_769_810_000_000_000_000; // 314.76981 ETH
    /// @dev Mint-sawtooth scale, cycles ≥ 1 (both phases). S·(1−D)/(1+D) = S/3.
    uint256 internal constant S_STAR = 104_923_270_000_000_000_000; // 104.92327 ETH
    /// @dev Phase-2 redemption-floor scale. (1−D)·S = S/2.
    uint256 internal constant S_F = 157_384_905_000_000_000_000; // 157.384905 ETH
    /// @dev K/3, used to build K_n (D/(1+D) = 1/3 at D = 0.5).
    uint256 internal constant K_OVER_3 = 7_000_000e18;

    /// @dev Phase-1→2 boundary: s_5 = 31/32·K (96.875%). An ordinary cycle low.
    uint256 internal constant Q_DEP = 20_343_750e18;
    /// @dev Phase-2 floor activation: (s_4+s_5)/2 (95.3125%). Below it redeem = sawtooth.
    uint256 internal constant Q_MID = 20_015_625e18;
    /// @dev Scenario-3 redeem-bridge cap: 33/32·K (§6.3). On [Q_MID, Q_DEP] the redeem curve
    ///      is the original-Sato hyperbola S/(CAP_MID−q): it meets the mint sawtooth at Q_MID
    ///      (intersect, no step) and the (1−D)·Sato floor at Q_DEP (rejoin). Continuous both ends.
    uint256 internal constant CAP_MID = 21_656_250e18; // 33K/32
    /// @dev Terminal mint latch = s₂₄ (cycle-24 low, ≈ 99.999994% of K). Snapped to a halving
    ///      boundary so minting closes cleanly entering cycle 24, with supply as close to K as is
    ///      meaningful: only ≈ 1.25 ATO is left unmintable (the economically-unreachable near-cap
    ///      dust — the mint price there is ≈ 8.4e6× genesis). s₂₄ is the DEEPEST cycle low where the
    ///      strict no-drain envelope priceAt(q) ≥ floorPriceAt(q) still holds to the wei (it begins
    ///      to breach by ≤~1e7-wei rounding dust only from cycle ~28 on). The latch sits ≈ 1.25e18 wei
    ///      (≈ 2.06e11× the `priceAt` precision cliff at cap(60) = K − 6,071,532 wei) clear of the
    ///      numerically-unsafe region, so cycleOf/exp/ln stay exact. Enforced by the hook (§10.5).
    uint256 internal constant Q_CLOSE = K - (K >> 24); // s₂₄ = 20_999_998.748302459716796875 ATO

    uint256 internal constant WAD = 1e18;

    /*//////////////////////////////////////////////////////////////
                       CYCLE INDEXING & PARAMS (§4.2)
    //////////////////////////////////////////////////////////////*/

    /// @notice Cycle index of supply `q`: bands are [s_n, s_{n+1}); a point on a
    ///         boundary belongs to the upper cycle (its start). n = ⌊log2(K/(K−q))⌋.
    /// @dev    Bounded loop on the gap g = K−q (no fixed-point log2). Caller guarantees
    ///         q < K (the hook never mints to the cap; mintClosed latches at Q_CLOSE).
    function cycleOf(uint256 q) internal pure returns (uint256 n) {
        uint256 g = K - q; // exact integer subtraction
        uint256 half = K >> 1;
        // largest n with g <= K·2^-n  ⟺  g <= half repeatedly
        while (g <= half && n < 60) {
            half >>= 1;
            unchecked { ++n; }
        }
    }

    /// @notice s_n = K·(1 − 2^-n): supply at the bottom of cycle n. s_0 = 0.
    function sLow(uint256 n) internal pure returns (uint256) {
        return K - (K >> n);
    }

    /// @notice Mint-sawtooth scale for cycle n: S (cycle 0) or S* (n ≥ 1).
    function cycleScale(uint256 n) internal pure returns (uint256) {
        return n == 0 ? S : S_STAR;
    }

    /// @notice Re-anchored cap for cycle n: K (cycle 0) or K_n = K − (K/3)·2^-n.
    function cycleCap(uint256 n) internal pure returns (uint256) {
        return n == 0 ? K : K - (K_OVER_3 >> n);
    }

    /*//////////////////////////////////////////////////////////////
                       WITHIN-CYCLE PRIMITIVES (§4.1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Marginal mint (sawtooth) price at q, scaled ×1e18 (wei/token × 1e18).
    function priceAt(uint256 q) internal pure returns (uint256) {
        uint256 n = cycleOf(q);
        return FixedPointMathLib.fullMulDiv(cycleScale(n), WAD, cycleCap(n) - q);
    }

    /// @notice (1−D)·Sato envelope price F(q) = S_F/(K−q), scaled ×1e18. The trough-envelope
    ///         the mint sawtooth dominates everywhere (`priceAt ≥ floorPriceAt`, §6.2). On
    ///         [Q_MID, Q_DEP] the *active* redeem price is the higher bridge — see redeemPriceAt.
    function floorPriceAt(uint256 q) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(S_F, WAD, K - q);
    }

    /// @notice Actual Phase-2 marginal redeem price at q (scenario-3, §6.3), scaled ×1e18:
    ///         reversible sawtooth below Q_MID, the bridge S/(CAP_MID−q) on [Q_MID, Q_DEP],
    ///         the (1−D)·Sato floor S_F/(K−q) above Q_DEP. Continuous at both joins, and
    ///         floorPriceAt(q) ≤ redeemPriceAt(q) ≤ priceAt(q) on [Q_MID, Q_DEP] (no-drain).
    function redeemPriceAt(uint256 q, bool phase2) internal pure returns (uint256) {
        if (!phase2 || q <= Q_MID) return priceAt(q);
        if (q <= Q_DEP) return FixedPointMathLib.fullMulDiv(S, WAD, CAP_MID - q);
        return FixedPointMathLib.fullMulDiv(S_F, WAD, K - q);
    }

    /// @notice ETH (wei) to move along curve (sc,cap) from a up to b (a ≤ b), rounded down.
    /// @dev    sc·ln((cap−a)/(cap−b)). Caller must keep (a,b) within a single segment so
    ///         the ratio stays bounded (≤ 2/(1−D) = 4 within a sawtooth cycle); the smooth
    ///         floor takes the whole [a,b] in one call (one curve, no per-cycle split).
    function ethBetween(uint256 sc, uint256 cap, uint256 a, uint256 b)
        internal
        pure
        returns (uint256)
    {
        if (b <= a) return 0;
        uint256 ratioWad = FixedPointMathLib.fullMulDiv(cap - a, WAD, cap - b); // ≥ 1e18
        int256 lnv = FixedPointMathLib.lnWad(int256(ratioWad)); // ≥ 0
        return FixedPointMathLib.fullMulDiv(sc, uint256(lnv), WAD); // round down
    }

    /// @notice Tokens minted by spending `e` wei from q along (sc,cap), rounded down.
    /// @dev    (cap−q)·(1 − exp(−e/sc)). Caller keeps `e` within one cycle (e ≤ cycle width)
    ///         so the exp argument stays small (≤ ln(2/(1−D)) = ln4 ≈ 1.39).
    function tokensForEth(uint256 sc, uint256 cap, uint256 q, uint256 e)
        internal
        pure
        returns (uint256)
    {
        if (e == 0) return 0;
        int256 x = -int256(FixedPointMathLib.fullMulDiv(e, WAD, sc)); // −e/sc in wad
        uint256 expv = uint256(FixedPointMathLib.expWad(x)); // exp(−e/sc) ∈ (0,1e18]
        uint256 oneMinus = WAD - expv;
        return FixedPointMathLib.fullMulDiv(cap - q, oneMinus, WAD); // round down
    }

    /*//////////////////////////////////////////////////////////////
                          ORCHESTRATORS (§4.3)
    //////////////////////////////////////////////////////////////*/

    /// @notice Exact-input buy: spend `ethIn` from `cursor`, minting along the sawtooth.
    ///         Phase-independent (mint always rides the same sawtooth; §5.3).
    /// @return tokensOut tokens minted (rounded down). newCursor = cursor + tokensOut.
    function mintFor(uint256 cursor, uint256 ethAmount)
        internal
        pure
        returns (uint256 tokensOut, uint256 newCursor)
    {
        uint256 q = cursor;
        uint256 rem = ethAmount;
        uint256 n = cycleOf(q);
        // Walk cycles up; integrate pre-drop at cycle-n pricing, post-drop beyond the boundary.
        while (rem > 0 && n < 60) {
            uint256 sc = cycleScale(n);
            uint256 cap = cycleCap(n);
            uint256 top = sLow(n + 1); // this cycle's top = next cycle's low
            uint256 toTop = ethBetween(sc, cap, q, top);
            if (rem <= toTop) {
                uint256 m = tokensForEth(sc, cap, q, rem);
                tokensOut += m;
                q += m;
                rem = 0;
            } else {
                tokensOut += (top - q); // exact token chunk to the boundary
                rem -= toTop;
                q = top;
                unchecked { ++n; }
            }
        }
        // The loop only exits with rem > 0 if it hit the cycle cap (q ≈ K, far past Q_CLOSE).
        // Revert rather than silently dropping the leftover ETH. The hook's
        // mintClosed latch makes this unreachable in normal operation.
        if (rem != 0) revert InputExceedsCapacity();
        newCursor = q;
    }

    error InputExceedsCapacity();

    /// @notice Exact-input redeem: burn `tokensIn` walking DOWN from `cursor` (= totalSupply).
    /// @param  phase2 If true, redeem follows the floor F for q ≥ Q_MID and the sawtooth below;
    ///         if false (Phase 1), the sawtooth everywhere.
    /// @return ethOut ETH paid (rounded down). newCursor = cursor − tokensIn.
    function burnFor(uint256 cursor, uint256 tokensIn, bool phase2)
        internal
        pure
        returns (uint256 ethOut, uint256 newCursor)
    {
        uint256 q = cursor;
        uint256 rem = tokensIn;
        while (rem > 0) {
            if (phase2 && q > Q_DEP) {
                // (1−D)·Sato floor F = S_F/(K−q): one curve across all P2 boundaries, down to Q_DEP.
                uint256 lo = q - rem > Q_DEP ? q - rem : Q_DEP;
                ethOut += ethBetween(S_F, K, lo, q);
                unchecked {
                    rem -= (q - lo);
                }
                q = lo;
            } else if (phase2 && q > Q_MID) {
                // Scenario-3 bridge F′ = S/(CAP_MID−q) on [Q_MID, Q_DEP], down to Q_MID (§6.3).
                uint256 lo = q - rem > Q_MID ? q - rem : Q_MID;
                ethOut += ethBetween(S, CAP_MID, lo, q);
                unchecked {
                    rem -= (q - lo);
                }
                q = lo;
            } else {
                // Sawtooth region. Split at each s_n (price jumps UP by 1/(1−D) going down).
                uint256 n = cycleOf(q);
                uint256 bottom = sLow(n);
                if (q == bottom && n > 0) {
                    // q sits exactly on s_n (start of cycle n): the segment below is cycle n−1.
                    unchecked { --n; }
                    bottom = sLow(n);
                }
                uint256 floorLo = q - rem; // may underflow guard: rem ≤ q always (supply)
                uint256 lo = floorLo > bottom ? floorLo : bottom;
                ethOut += ethBetween(cycleScale(n), cycleCap(n), lo, q);
                unchecked {
                    rem -= (q - lo);
                }
                q = lo;
            }
        }
        newCursor = q;
    }

    /*//////////////////////////////////////////////////////////////
                       LIABILITY ORACLES (§4.4)
    //////////////////////////////////////////////////////////////*/

    /// @notice Cumulative sawtooth ETH deposited to reach mint frontier q (= W_0 + (n−1)W* + partial).
    function ethIn(uint256 q) internal pure returns (uint256 total) {
        uint256 n = cycleOf(q);
        for (uint256 k = 0; k < n; ++k) {
            total += ethBetween(cycleScale(k), cycleCap(k), sLow(k), sLow(k + 1));
        }
        total += ethBetween(cycleScale(n), cycleCap(n), sLow(n), q);
    }

    /// @notice Redemption liability L(q): sawtooth (Phase 1 / below Q_MID), then the scenario-3
    ///         bridge on [Q_MID, Q_DEP], then the (1−D)·Sato floor above Q_DEP (§4.4/§6.3).
    function liability(uint256 q, bool phase2) internal pure returns (uint256) {
        if (!phase2 || q <= Q_MID) return ethIn(q);
        uint256 owed = ethIn(Q_MID); // [0, Q_MID] redeems on the reversible sawtooth
        if (q <= Q_DEP) {
            return owed + ethBetween(S, CAP_MID, Q_MID, q); // + bridge
        }
        return owed + ethBetween(S, CAP_MID, Q_MID, Q_DEP) // + full bridge
            + ethBetween(S_F, K, Q_DEP, q); //               + (1−D)·Sato floor above Q_DEP
    }
}
