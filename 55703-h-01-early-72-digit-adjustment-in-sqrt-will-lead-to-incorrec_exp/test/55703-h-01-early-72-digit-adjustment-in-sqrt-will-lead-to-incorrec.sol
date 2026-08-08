// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Forte Float128 — [H-01] Early 72-digit adjustment in sqrt will lead to
    incorrect result exponent calculation
    (Code4rena 2025-04-forte-float128-solidity-library, finding #55703)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: in the large-number branch of Float128.sqrt, when rMan has 73
    digits the code trims it (`rMan /= 10; ++rExp`) *before* halving the
    exponent. Integer division then discards the +1 (`2195/2 = 1097` instead
    of `1097+1 = 1098`), so the returned float is 10× too small.

    The blamed adjustment block (L735–L742) is preserved verbatim. Upstream
    intermediate values match the finding PoC for mantissa=3.82e71, exp=2267
    (real value 3.82e2338) after the L-size / parity setup; Uint512.sqrt512 is
    inlined so the 73-digit rMan is actually computed.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Minimal Uint512 surface used by the large sqrt path.
library Uint512 {
    function mul256x256(uint256 a, uint256 b) internal pure returns (uint256 r0, uint256 r1) {
        assembly {
            let mm := mulmod(a, b, not(0))
            r0 := mul(a, b)
            r1 := sub(sub(mm, r0), lt(mm, r0))
        }
    }

    function sqrt256(uint256 x) internal pure returns (uint256 s) {
        if (x == 0) return 0;
        assembly {
            s := 1
            let xAux := x
            let cmp := or(gt(xAux, 0x100000000000000000000000000000000), eq(xAux, 0x100000000000000000000000000000000))
            xAux := sar(mul(cmp, 128), xAux)
            s := shl(mul(cmp, 64), s)
            cmp := or(gt(xAux, 0x10000000000000000), eq(xAux, 0x10000000000000000))
            xAux := sar(mul(cmp, 64), xAux)
            s := shl(mul(cmp, 32), s)
            cmp := or(gt(xAux, 0x100000000), eq(xAux, 0x100000000))
            xAux := sar(mul(cmp, 32), xAux)
            s := shl(mul(cmp, 16), s)
            cmp := or(gt(xAux, 0x10000), eq(xAux, 0x10000))
            xAux := sar(mul(cmp, 16), xAux)
            s := shl(mul(cmp, 8), s)
            cmp := or(gt(xAux, 0x100), eq(xAux, 0x100))
            xAux := sar(mul(cmp, 8), xAux)
            s := shl(mul(cmp, 4), s)
            cmp := or(gt(xAux, 0x10), eq(xAux, 0x10))
            xAux := sar(mul(cmp, 4), xAux)
            s := shl(mul(cmp, 2), s)
            s := shl(mul(or(gt(xAux, 0x8), eq(xAux, 0x8)), 2), s)
        }
        unchecked {
            s = (s + x / s) >> 1;
            s = (s + x / s) >> 1;
            s = (s + x / s) >> 1;
            s = (s + x / s) >> 1;
            s = (s + x / s) >> 1;
            s = (s + x / s) >> 1;
            s = (s + x / s) >> 1;
            uint256 roundedDownResult = x / s;
            return s >= roundedDownResult ? roundedDownResult : s;
        }
    }

    function sqrt512(uint256 a0, uint256 a1) internal pure returns (uint256 s) {
        if (a1 == 0) return sqrt256(a0);
        uint256 shift;
        assembly {
            let digits := mul(lt(a1, 0x100000000000000000000000000000000), 128)
            a1 := shl(digits, a1)
            shift := add(shift, digits)
            digits := mul(lt(a1, 0x1000000000000000000000000000000000000000000000000), 64)
            a1 := shl(digits, a1)
            shift := add(shift, digits)
            digits := mul(lt(a1, 0x100000000000000000000000000000000000000000000000000000000), 32)
            a1 := shl(digits, a1)
            shift := add(shift, digits)
            digits := mul(lt(a1, 0x1000000000000000000000000000000000000000000000000000000000000), 16)
            a1 := shl(digits, a1)
            shift := add(shift, digits)
            digits := mul(lt(a1, 0x100000000000000000000000000000000000000000000000000000000000000), 8)
            a1 := shl(digits, a1)
            shift := add(shift, digits)
            digits := mul(lt(a1, 0x1000000000000000000000000000000000000000000000000000000000000000), 4)
            a1 := shl(digits, a1)
            shift := add(shift, digits)
            digits := mul(lt(a1, 0x4000000000000000000000000000000000000000000000000000000000000000), 2)
            a1 := shl(digits, a1)
            shift := add(shift, digits)
            a1 := or(a1, shr(sub(256, shift), a0))
            a0 := shl(shift, a0)
        }
        uint256 sp = sqrt256(a1);
        uint256 rp = a1 - (sp * sp);
        uint256 nom;
        uint256 denom;
        uint256 u;
        uint256 q;
        assembly {
            nom := or(shl(128, rp), shr(128, a0))
            denom := shl(1, sp)
            q := div(nom, denom)
            u := mod(nom, denom)
            let carry := shr(128, rp)
            let x := mul(carry, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
            q := add(q, div(x, denom))
            u := add(u, add(carry, mod(x, denom)))
            q := add(q, div(u, denom))
            u := mod(u, denom)
        }
        unchecked {
            s = (sp << 128) + q;
            uint256 rl = ((u << 128) | (a0 & 0xffffffffffffffffffffffffffffffff));
            uint256 rr = q * q;
            if ((q >> 128) > (u >> 128) || (((q >> 128) == (u >> 128)) && rl < rr)) {
                s = s - 1;
            }
            return s >> (shift / 2);
        }
    }
}

/// @notice Reduced large-number branch of Float128.sqrt with the buggy
///         exponent adjustment preserved verbatim.
contract VulnerableSqrt {
    uint256 constant BASE = 10;
    uint256 constant MAX_DIGITS_L = 72;
    uint256 constant DIGIT_DIFF_L_M = 34;
    uint256 constant MAX_L_DIGIT_NUMBER =
        999999999999999999999999999999999999999999999999999999999999999999999999;
    uint256 constant BASE_TO_THE_MAX_DIGITS_L =
        1000000000000000000000000000000000000000000000000000000000000000000000000;
    uint256 constant BASE_TO_THE_DIGIT_DIFF = 10000000000000000000000000000000000;
    int256 constant MAXIMUM_EXPONENT = -18;
    uint256 constant ZERO_OFFSET = 8192;

    /// @dev Large-path sqrt body. `aMan`/`aExp` are the post-parity values
    ///      (aExp already de-offset, even). Matches Float128.sol L733–L748.
    function sqrtLargePath(uint256 aMan, int256 aExp)
        external
        pure
        returns (uint256 rMan, int256 rExp, bool Lresult)
    {
        (uint256 a0, uint256 a1) = Uint512.mul256x256(aMan, BASE_TO_THE_MAX_DIGITS_L);
        rMan = Uint512.sqrt512(a0, a1);
        rExp = aExp - int256(MAX_DIGITS_L);
        Lresult = true;
        unchecked {
            // ---- verbatim Float128.sqrt L738–L742 (buggy order) ----
            if (rMan > MAX_L_DIGIT_NUMBER) {
                rMan /= BASE;
                ++rExp;
            }
            rExp = (rExp) / 2; // @> VULN: halve AFTER 73-digit trim; integer div drops the +1 (2195/2=1097, not 1098)
            // FIX: rExp = (rExp) / 2;  THEN  if (rMan > MAX_L) { rMan /= BASE; ++rExp; }
            // ---- end blamed block; residual L→M downscale kept for fidelity ----
            if (rExp <= MAXIMUM_EXPONENT - int256(DIGIT_DIFF_L_M)) {
                rMan /= BASE_TO_THE_DIGIT_DIFF;
                rExp += int256(DIGIT_DIFF_L_M);
                Lresult = false;
            }
            rExp += int256(ZERO_OFFSET);
        }
    }

    /// @dev Same math with the fixed order (halve first) for the control check.
    function sqrtLargePathFixed(uint256 aMan, int256 aExp)
        external
        pure
        returns (uint256 rMan, int256 rExp, bool Lresult)
    {
        (uint256 a0, uint256 a1) = Uint512.mul256x256(aMan, BASE_TO_THE_MAX_DIGITS_L);
        rMan = Uint512.sqrt512(a0, a1);
        rExp = aExp - int256(MAX_DIGITS_L);
        Lresult = true;
        unchecked {
            rExp = (rExp) / 2;
            if (rMan > MAX_L_DIGIT_NUMBER) {
                rMan /= BASE;
                ++rExp;
            }
            if (rExp <= MAXIMUM_EXPONENT - int256(DIGIT_DIFF_L_M)) {
                rMan /= BASE_TO_THE_DIGIT_DIFF;
                rExp += int256(DIGIT_DIFF_L_M);
                Lresult = false;
            }
            rExp += int256(ZERO_OFFSET);
        }
    }
}

contract Exploit {
    VulnerableSqrt public v; // CREATE nonce 1

    constructor() {
        v = new VulnerableSqrt();
    }

    function run() external {
        // Intermediate state from Float128.sqrt for the finding PoC input
        //   mantissa = 382…000 (72 digits), exponent = 2267  (real 3.82e2338)
        // after L-size confirm + parity fix (aExp was odd → *10, --exp):
        uint256 aMan = 3820000000000000000000000000000000000000000000000000000000000000000000000; // 73 digits
        int256 aExp = 2266; // de-offset, even

        (uint256 buggyMan, int256 buggyExpOffset, bool buggyL) = v.sqrtLargePath(aMan, aExp);
        (uint256 fixedMan, int256 fixedExpOffset, bool fixedL) = v.sqrtLargePathFixed(aMan, aExp);

        // Strip ZERO_OFFSET for human exponents.
        int256 buggyExp = buggyExpOffset - int256(8192);
        int256 fixedExp = fixedExpOffset - int256(8192);

        require(buggyL && fixedL, "both stay L-size for this input");
        require(buggyMan == fixedMan, "mantissa trim matches");
        require(
            buggyMan == 195448202856920636357880189105054200888773427974465741390571759690634834,
            "expected 72-digit sqrt mantissa"
        );
        // Harm: exponent is off-by-one → result is 10× too small.
        require(buggyExp == 1097, "buggy exponent");
        require(fixedExp == 1098, "fixed exponent");
        require(buggyExp + 1 == fixedExp, "off-by-one exponent harm");
    }
}
