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
import {Curve} from "./Curve.sol";

/// @title  CurveAccountant — phase machine, cursors, reserve & fee accounting
/// @notice The solvency-bearing core, independent of Uniswap v4. The hook inherits this
///         and wires v4 swap deltas + ATO mint/burn into `_processBuy`/`_processSell`.
/// @dev    Solvency guarantee (curve-spec §5.4/§5.5): `reserve` is real ETH backing the
///         curve; `feesAccrued` is parked for stakers and never backs it. Redemption is
///         CAPPED at `reserve`, so the contract can never pay out more ETH than it holds —
///         this absorbs the bounded `exp`/`ln` inversion dust and makes
///         `reserve ≥ 0` hold by construction. Rounding favors the reserve (§7): tokens
///         down (in Curve), fees up (here).
abstract contract CurveAccountant {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    /*//////////////////////////////////////////////////////////////
                                 STATE (§5.1)
    //////////////////////////////////////////////////////////////*/

    uint256 public mintCursor; // supply position priced for minting; Phase-2 monotone high-water mark
    uint256 public totalMinted; // == ATO.totalSupply() == redeemCursor
    uint256 public reserve; // = backing ETH (address(this).balance − feesAccrued)
    uint256 public feesAccrued; // ETH for the staking stream; never backs the curve
    bool public phase2; // false = Phase 1 (reversible), true = Phase 2 (ratchet + floor)
    bool public mintClosed; // terminal latch on mintCursor

    /*//////////////////////////////////////////////////////////////
                              FEES (mining-spec §1.1/§9)
    //////////////////////////////////////////////////////////////*/

    /// @dev Fee unit: parts-per-million. 0.60% = 6000, 0.30% = 3000.
    uint256 internal constant FEE_DENOM = 1_000_000;
    uint256 internal constant FEE_HI = 6_000; // 0.60%
    uint256 internal constant FEE_LO = 3_000; // 0.30%
    uint256 internal constant LN2 = 693_147_180_559_945_309; // ln2 · 1e18
    uint256 internal constant DEP_LN = 5 * LN2; // depCycle·ln2 = 5·ln2 (mult 1→32 across Phase 1)

    error MintClosed();
    error ExceedsSupply();

    /// @notice Public view of the Phase-1 dynamic fee (ppm) at supply `q`. Lets the Router price the
    ///         mint leg's effective cost net of fee when splitting (§5.1). NB: the *buy* fee is 0 in
    ///         Phase 2 (see `_processBuy`), so a caller must apply `phase2 ? 0 : dynamicFeePpm(q)`.
    function dynamicFeePpm(uint256 q) public pure returns (uint256) {
        return _dynamicFeePpm(q);
    }

    /// @notice Dynamic Phase-1 fee rate (ppm) at supply q, riding the sawtooth (§9.1):
    ///         feeFrac = 0.60% − 0.30%·clamp( ln(mult(q)) / (5·ln2), 0, 1 ).
    function _dynamicFeePpm(uint256 q) internal pure returns (uint256) {
        uint256 gen = Curve.priceAt(0);
        uint256 multWad = FixedPointMathLib.fullMulDiv(Curve.priceAt(q), 1e18, gen); // ≥ 1e18
        int256 lnMult = FixedPointMathLib.lnWad(int256(multWad)); // ≥ 0
        if (lnMult <= 0) return FEE_HI;
        uint256 frac = FixedPointMathLib.fullMulDiv(uint256(lnMult), 1e18, DEP_LN); // wad
        if (frac >= 1e18) return FEE_LO;
        return FEE_HI - FixedPointMathLib.fullMulDiv(FEE_HI - FEE_LO, frac, 1e18);
    }

    /// @dev fee on `amount` at `ppm`, rounded UP (favor reserve / staking stream).
    function _feeUp(uint256 amount, uint256 ppm) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(amount, ppm, FEE_DENOM);
    }

    /*//////////////////////////////////////////////////////////////
                            BUY / SELL (§5.2/§5.3)
    //////////////////////////////////////////////////////////////*/

    /// @notice Process a buy of `ethIn` wei. Mints along the sawtooth; flips to Phase 2
    ///         and latches `mintClosed` as the frontier crosses the thresholds.
    /// @return tokensOut tokens minted, fee ETH skimmed to the staking stream.
    function _processBuy(uint256 ethIn) internal returns (uint256 tokensOut, uint256 fee) {
        if (mintClosed) revert MintClosed();

        // Buy fee: dynamic across Phase 1, 0% in Phase 2 (mining-spec §9.2). Skim before the curve.
        fee = phase2 ? 0 : _feeUp(ethIn, _dynamicFeePpm(mintCursor));
        uint256 toCurve = ethIn - fee;

        (uint256 m, uint256 nc) = Curve.mintFor(mintCursor, toCurve);
        tokensOut = m;
        mintCursor = nc;
        totalMinted += m;
        reserve += toCurve;
        feesAccrued += fee;

        if (!phase2 && mintCursor >= Curve.Q_DEP) phase2 = true; // §5.3 one-way flip
        if (mintCursor >= Curve.Q_CLOSE) mintClosed = true; // §5.1 terminal latch (monotone cursor)
    }

    /// @notice Process a sell (redeem) of `tokensIn`. Pays ETH from reserve along the
    ///         Phase-1 sawtooth or the Phase-2 floor; Phase 1 retracts `mintCursor` (§5.2).
    /// @return ethOut ETH paid to the redeemer (post-fee), fee ETH skimmed.
    function _processSell(uint256 tokensIn) internal returns (uint256 ethOut, uint256 fee) {
        if (tokensIn > totalMinted) revert ExceedsSupply();

        (uint256 gross,) = Curve.burnFor(totalMinted, tokensIn, phase2);
        // SOLVENCY CAP: never pay out more than the reserve holds. Absorbs bounded
        // exp/ln inversion dust → reserve ≥ 0 by construction (curve-spec §5.4/§7).
        if (gross > reserve) gross = reserve;

        // Sell (redeem) fee: ALWAYS dynamic, sampled at the redeem cursor — it follows the
        // burn price down the curve. Unlike the buy fee, it is NOT flattened/zeroed in Phase 2:
        // the mint frontier ratchets and never retraces (so the mint fee locks to 0), but a
        // burn always traces back DOWN the curve, so its fee stays on the 0.6%→0.30% schedule
        // (rising back toward 0.6% as the cursor descends toward genesis). mining-spec §1.1.
        // Single-sample at the cursor (consistent with the buy leg); the per-trade approximation
        // is seller-favorable and bounded — fee-only, never touches `reserve` (see below).
        uint256 ppm = _dynamicFeePpm(totalMinted);
        fee = _feeUp(gross, ppm);
        ethOut = gross - fee;

        totalMinted -= tokensIn;
        if (!phase2) mintCursor = totalMinted; // §5.2: Phase 1 sells retract the frontier
        reserve -= gross;
        feesAccrued += fee;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS / ORACLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Redemption liability L(totalMinted) — the ETH owed to redeem all supply (§4.4).
    function liability() public view returns (uint256) {
        return Curve.liability(totalMinted, phase2);
    }

    /// @notice Realized structural surplus = reserve − L (Phase 2; ≥ 0). Skimmable to stakers.
    /// @dev    Conservative: withholds a small dust margin so the figure can never over-report
    ///         the truly-free ETH given the bounded exp/ln oracle dust. The staking
    ///         layer must only ever route what this returns.
    uint256 internal constant SURPLUS_DUST_MARGIN = 1e6; // wei (1e-12 ETH) ≫ observed ≤535 wei

    function surplus() public view returns (uint256) {
        uint256 floorPlusDust = liability() + SURPLUS_DUST_MARGIN;
        return reserve > floorPlusDust ? reserve - floorPlusDust : 0;
    }
}
