// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Uint512} from "../lib/Uint512.sol";
import {packedFloat} from "./Types.sol";

/**
 * @title Floating point Library base 10 with 38 or 72 digits signed
 * @dev the library uses the type packedFloat which is a uint under the hood
 * @author Inspired by a Python proposal by @miguel-ot and refined/implemented in Solidity by @oscarsernarosero @Palmerg4
 */

library Float128 {
    uint constant MANTISSA_MASK = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    uint constant MANTISSA_SIGN_MASK = 0x1000000000000000000000000000000000000000000000000000000000000;
    uint constant MANTISSA_L_FLAG_MASK = 0x2000000000000000000000000000000000000000000000000000000000000;
    uint constant EXPONENT_MASK = 0xfffc000000000000000000000000000000000000000000000000000000000000;
    uint constant TWO_COMPLEMENT_SIGN_MASK = 0x8000000000000000000000000000000000000000000000000000000000000000;
    uint constant BASE = 10;
    uint constant ZERO_OFFSET = 8192;
    uint constant ZERO_OFFSET_MINUS_1 = 8191;
    uint constant EXPONENT_BIT = 242;
    uint constant MAX_DIGITS_M = 38;
    uint constant MAX_DIGITS_M_X_2 = 76;
    uint constant MAX_DIGITS_M_MINUS_1 = 37;
    uint constant MAX_DIGITS_M_PLUS_1 = 39;
    uint constant MAX_DIGITS_L = 72;
    uint constant MAX_DIGITS_L_MINUS_1 = 71;
    uint constant MAX_DIGITS_L_PLUS_1 = 73;
    uint constant DIGIT_DIFF_L_M = 34;
    uint constant DIGIT_DIFF_L_M_PLUS_1 = 35;
    uint constant DIGIT_DIFF_76_L_MINUS_1 = 3;
    uint constant DIGIT_DIFF_76_L = 4;
    uint constant DIGIT_DIFF_76_L_PLUS_1 = 5;
    uint constant MAX_M_DIGIT_NUMBER = 99999999999999999999999999999999999999;
    uint constant MIN_M_DIGIT_NUMBER = 10000000000000000000000000000000000000;
    uint constant MAX_L_DIGIT_NUMBER = 999999999999999999999999999999999999999999999999999999999999999999999999;
    uint constant MIN_L_DIGIT_NUMBER = 100000000000000000000000000000000000000000000000000000000000000000000000;
    uint constant BASE_TO_THE_MAX_DIGITS_L = 1000000000000000000000000000000000000000000000000000000000000000000000000;
    uint constant BASE_TO_THE_DIGIT_DIFF = 10000000000000000000000000000000000;
    uint constant BASE_TO_THE_DIGIT_DIFF_PLUS_1 = 100000000000000000000000000000000000;
    uint constant BASE_TO_THE_MAX_DIGITS_M_MINUS_1 = 10000000000000000000000000000000000000;
    uint constant BASE_TO_THE_MAX_DIGITS_M = 100000000000000000000000000000000000000;
    uint constant BASE_TO_THE_MAX_DIGITS_M_PLUS_1 = 1000000000000000000000000000000000000000;
    uint constant BASE_TO_THE_MAX_DIGITS_M_X_2 =
        10000000000000000000000000000000000000000000000000000000000000000000000000000;
    uint constant BASE_TO_THE_DIFF_76_L_MINUS_1 = 1_000;
    uint constant BASE_TO_THE_DIFF_76_L = 10_000;
    uint constant BASE_TO_THE_DIFF_76_L_PLUS_1 = 100_000;
    uint constant MAX_75_DIGIT_NUMBER = 999999999999999999999999999999999999999999999999999999999999999999999999999;
    uint constant MAX_76_DIGIT_NUMBER = 9999999999999999999999999999999999999999999999999999999999999999999999999999;
    int constant MAXIMUM_EXPONENT = -18; // guarantees all results will have at least 18 decimals in the M size. Autoscales to L if necessary

    /**
     * @dev adds 2 signed floating point numbers
     * @param a the first addend
     * @param b the second addend
     * @return r the result of a + b
     */
    function add(packedFloat a, packedFloat b) internal pure returns (packedFloat r) {
        uint addition;
        bool isSubtraction;
        bool sameExponent;
        if (packedFloat.unwrap(a) == 0) return b;
        if (packedFloat.unwrap(b) == 0) return a;
        assembly {
            let aL := gt(and(a, MANTISSA_L_FLAG_MASK), 0)
            let bL := gt(and(b, MANTISSA_L_FLAG_MASK), 0)
            isSubtraction := xor(and(a, MANTISSA_SIGN_MASK), and(b, MANTISSA_SIGN_MASK))
            // we extract the exponent and mantissas for both
            let aExp := and(a, EXPONENT_MASK)
            let bExp := and(b, EXPONENT_MASK)
            let aMan := and(a, MANTISSA_MASK)
            let bMan := and(b, MANTISSA_MASK)
            if iszero(or(aL, bL)) {
                // we add 38 digits of precision in the case of subtraction
                if gt(aExp, bExp) {
                    r := sub(aExp, shl(EXPONENT_BIT, MAX_DIGITS_M))
                    let adj := sub(shr(EXPONENT_BIT, r), shr(EXPONENT_BIT, bExp))
                    let neg := and(TWO_COMPLEMENT_SIGN_MASK, adj)
                    if neg {
                        bMan := mul(bMan, exp(BASE, sub(0, adj)))
                        aMan := mul(aMan, BASE_TO_THE_MAX_DIGITS_M)
                    }
                    if iszero(neg) {
                        bMan := sdiv(bMan, exp(BASE, adj))
                        aMan := mul(aMan, BASE_TO_THE_MAX_DIGITS_M)
                    }
                }
                if gt(bExp, aExp) {
                    r := sub(bExp, shl(EXPONENT_BIT, MAX_DIGITS_M))
                    let adj := sub(shr(EXPONENT_BIT, r), shr(EXPONENT_BIT, aExp))
                    let neg := and(TWO_COMPLEMENT_SIGN_MASK, adj)
                    if neg {
                        aMan := mul(aMan, exp(BASE, sub(0, adj)))
                        bMan := mul(bMan, BASE_TO_THE_MAX_DIGITS_M)
                    }
                    if iszero(neg) {
                        aMan := sdiv(aMan, exp(BASE, adj))
                        bMan := mul(bMan, BASE_TO_THE_MAX_DIGITS_M)
                    }
                }
                // if exponents are the same, we don't need to adjust the mantissas. We just set the result's exponent
                if eq(aExp, bExp) {
                    aMan := mul(aMan, BASE_TO_THE_MAX_DIGITS_M)
                    bMan := mul(bMan, BASE_TO_THE_MAX_DIGITS_M)
                    r := sub(aExp, shl(EXPONENT_BIT, MAX_DIGITS_M))
                    sameExponent := 1
                }
            }
            if or(aL, bL) {
                // we make sure both of them are size L before continuing
                if iszero(aL) {
                    aMan := mul(aMan, BASE_TO_THE_DIGIT_DIFF)
                    aExp := sub(aExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                if iszero(bL) {
                    bMan := mul(bMan, BASE_TO_THE_DIGIT_DIFF)
                    bExp := sub(bExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                // we adjust the significant digits and set the exponent of the result
                if gt(aExp, bExp) {
                    r := sub(aExp, shl(EXPONENT_BIT, DIGIT_DIFF_76_L))
                    let adj := sub(shr(EXPONENT_BIT, r), shr(EXPONENT_BIT, bExp))
                    let neg := and(TWO_COMPLEMENT_SIGN_MASK, adj)
                    if neg {
                        bMan := mul(bMan, exp(BASE, sub(0, adj)))
                        aMan := mul(aMan, BASE_TO_THE_DIFF_76_L)
                    }
                    if iszero(neg) {
                        bMan := sdiv(bMan, exp(BASE, adj))
                        aMan := mul(aMan, BASE_TO_THE_DIFF_76_L)
                    }
                }
                if gt(bExp, aExp) {
                    r := sub(bExp, shl(EXPONENT_BIT, DIGIT_DIFF_76_L))
                    let adj := sub(shr(EXPONENT_BIT, r), shr(EXPONENT_BIT, aExp))
                    let neg := and(TWO_COMPLEMENT_SIGN_MASK, adj)
                    if neg {
                        aMan := mul(aMan, exp(BASE, sub(0, adj)))
                        bMan := mul(bMan, BASE_TO_THE_DIFF_76_L)
                    }
                    if iszero(neg) {
                        aMan := sdiv(aMan, exp(BASE, adj))
                        bMan := mul(bMan, BASE_TO_THE_DIFF_76_L)
                    }
                }
                // // if exponents are the same, we don't need to adjust the mantissas. We just set the result's exponent
                if eq(aExp, bExp) {
                    aMan := mul(aMan, BASE_TO_THE_DIFF_76_L)
                    bMan := mul(bMan, BASE_TO_THE_DIFF_76_L)
                    r := sub(aExp, shl(EXPONENT_BIT, DIGIT_DIFF_76_L))
                    sameExponent := 1
                }
            }
            // now we convert to 2's complement to carry out the operation
            if and(b, MANTISSA_SIGN_MASK) {
                bMan := sub(0, bMan)
            }
            if and(a, MANTISSA_SIGN_MASK) {
                aMan := sub(0, aMan)
            }
            // now we can add/subtract
            addition := add(aMan, bMan)
            // encoding the unnormalized result
            if and(TWO_COMPLEMENT_SIGN_MASK, addition) {
                r := or(r, MANTISSA_SIGN_MASK) // assign the negative sign
                addition := sub(0, addition) // convert back from 2's complement
            }
            if iszero(addition) {
                r := 0
            }
        }
        // normalization
        if (packedFloat.unwrap(r) > 0) {
            uint rExp;
            assembly {
                rExp := shr(EXPONENT_BIT, r)
            }
            if (isSubtraction) {
                // subtraction case can have a number of digits anywhere from 1 to 76
                // we might get a normalized result, so we only normalize if necessary
                if (
                    !((addition <= MAX_M_DIGIT_NUMBER && addition >= MIN_M_DIGIT_NUMBER) ||
                        (addition <= MAX_L_DIGIT_NUMBER && addition >= MIN_L_DIGIT_NUMBER))
                ) {
                    uint digitsMantissa = findNumberOfDigits(addition);
                    assembly {
                        let mantissaReducer := sub(digitsMantissa, MAX_DIGITS_M)
                        let isResultL := slt(MAXIMUM_EXPONENT, add(sub(rExp, ZERO_OFFSET), mantissaReducer))
                        if isResultL {
                            mantissaReducer := sub(mantissaReducer, DIGIT_DIFF_L_M)
                            r := or(r, MANTISSA_L_FLAG_MASK)
                        }
                        let negativeReducer := and(TWO_COMPLEMENT_SIGN_MASK, mantissaReducer)
                        if negativeReducer {
                            addition := mul(addition, exp(BASE, sub(0, mantissaReducer)))
                            r := sub(r, shl(EXPONENT_BIT, sub(0, mantissaReducer)))
                        }
                        if iszero(negativeReducer) {
                            addition := div(addition, exp(BASE, mantissaReducer))
                            r := add(r, shl(EXPONENT_BIT, mantissaReducer))
                        }
                    }
                } else if (
                    addition >= MIN_L_DIGIT_NUMBER &&
                    rExp < (ZERO_OFFSET - uint(MAXIMUM_EXPONENT * -1) - DIGIT_DIFF_L_M)
                ) {
                    assembly {
                        addition := sdiv(addition, BASE_TO_THE_DIGIT_DIFF)
                        r := add(r, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                    }
                }
            } else {
                // addition case is simpler since it can only have 2 possibilities: same digits as its addends,
                // or + 1 digits due to an "overflow"
                assembly {
                    let isGreaterThan76Digits := gt(addition, MAX_76_DIGIT_NUMBER)
                    let maxExp := sub(
                        sub(sub(add(ZERO_OFFSET, MAXIMUM_EXPONENT), DIGIT_DIFF_L_M), DIGIT_DIFF_76_L),
                        isGreaterThan76Digits
                    )
                    let _isM := or(eq(rExp, maxExp), lt(rExp, maxExp))
                    if _isM {
                        addition := div(addition, BASE_TO_THE_MAX_DIGITS_M)
                        r := add(r, shl(EXPONENT_BIT, MAX_DIGITS_M))
                    }
                    if iszero(_isM) {
                        addition := div(addition, BASE_TO_THE_DIFF_76_L)
                        r := add(r, shl(EXPONENT_BIT, DIGIT_DIFF_76_L))
                        r := add(r, MANTISSA_L_FLAG_MASK)
                    }
                    if or(
                        gt(addition, MAX_L_DIGIT_NUMBER),
                        and(lt(addition, MIN_L_DIGIT_NUMBER), gt(addition, MAX_M_DIGIT_NUMBER))
                    ) {
                        addition := div(addition, BASE)
                        r := add(r, shl(EXPONENT_BIT, 1))
                    }
                }
            }
            assembly {
                r := or(r, addition)
            }
        }
    }

    /**
     * @dev gets the difference between 2 signed floating point numbers
     * @param a the minuend
     * @param b the subtrahend
     * @return r the result of a - b
     * @notice this version of the function uses only the packedFloat type
     */
    function sub(packedFloat a, packedFloat b) internal pure returns (packedFloat r) {
        uint addition;
        bool isSubtraction;
        bool sameExponent;
        if (packedFloat.unwrap(a) == 0) {
            assembly {
                if gt(b, 0) {
                    b := xor(MANTISSA_SIGN_MASK, b)
                }
            }
            return b;
        }
        if (packedFloat.unwrap(b) == 0) return a;
        assembly {
            let aL := gt(and(a, MANTISSA_L_FLAG_MASK), 0)
            let bL := gt(and(b, MANTISSA_L_FLAG_MASK), 0)
            isSubtraction := eq(and(a, MANTISSA_SIGN_MASK), and(b, MANTISSA_SIGN_MASK))
            // we extract the exponent and mantissas for both
            let aExp := and(a, EXPONENT_MASK)
            let bExp := and(b, EXPONENT_MASK)
            let aMan := and(a, MANTISSA_MASK)
            let bMan := and(b, MANTISSA_MASK)
            if iszero(or(aL, bL)) {
                // we add 38 digits of precision in the case of subtraction
                if gt(aExp, bExp) {
                    r := sub(aExp, shl(EXPONENT_BIT, MAX_DIGITS_M))
                    let adj := sub(shr(EXPONENT_BIT, r), shr(EXPONENT_BIT, bExp))
                    let neg := and(TWO_COMPLEMENT_SIGN_MASK, adj)
                    if neg {
                        bMan := mul(bMan, exp(BASE, sub(0, adj)))
                        aMan := mul(aMan, BASE_TO_THE_MAX_DIGITS_M)
                    }
                    if iszero(neg) {
                        bMan := sdiv(bMan, exp(BASE, adj))
                        aMan := mul(aMan, BASE_TO_THE_MAX_DIGITS_M)
                    }
                }
                if gt(bExp, aExp) {
                    r := sub(bExp, shl(EXPONENT_BIT, MAX_DIGITS_M))
                    let adj := sub(shr(EXPONENT_BIT, r), shr(EXPONENT_BIT, aExp))
                    let neg := and(TWO_COMPLEMENT_SIGN_MASK, adj)
                    if neg {
                        aMan := mul(aMan, exp(BASE, sub(0, adj)))
                        bMan := mul(bMan, BASE_TO_THE_MAX_DIGITS_M)
                    }
                    if iszero(neg) {
                        aMan := sdiv(aMan, exp(BASE, adj))
                        bMan := mul(bMan, BASE_TO_THE_MAX_DIGITS_M)
                    }
                }
                // if exponents are the same, we don't need to adjust the mantissas. We just set the result's exponent
                if eq(aExp, bExp) {
                    aMan := mul(aMan, BASE_TO_THE_MAX_DIGITS_M)
                    bMan := mul(bMan, BASE_TO_THE_MAX_DIGITS_M)
                    r := sub(aExp, shl(EXPONENT_BIT, MAX_DIGITS_M))
                    sameExponent := 1
                }
            }
            if or(aL, bL) {
                // we make sure both of them are size L before continuing
                if iszero(aL) {
                    aMan := mul(aMan, BASE_TO_THE_DIGIT_DIFF)
                    aExp := sub(aExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                if iszero(bL) {
                    bMan := mul(bMan, BASE_TO_THE_DIGIT_DIFF)
                    bExp := sub(bExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                // we adjust the significant digits and set the exponent of the result
                if gt(aExp, bExp) {
                    r := sub(aExp, shl(EXPONENT_BIT, DIGIT_DIFF_76_L))
                    let adj := sub(shr(EXPONENT_BIT, r), shr(EXPONENT_BIT, bExp))
                    let neg := and(TWO_COMPLEMENT_SIGN_MASK, adj)
                    if neg {
                        bMan := mul(bMan, exp(BASE, sub(0, adj)))
                        aMan := mul(aMan, BASE_TO_THE_DIFF_76_L)
                    }
                    if iszero(neg) {
                        bMan := sdiv(bMan, exp(BASE, adj))
                        aMan := mul(aMan, BASE_TO_THE_DIFF_76_L)
                    }
                }
                if gt(bExp, aExp) {
                    r := sub(bExp, shl(EXPONENT_BIT, DIGIT_DIFF_76_L))
                    let adj := sub(shr(EXPONENT_BIT, r), shr(EXPONENT_BIT, aExp))
                    let neg := and(TWO_COMPLEMENT_SIGN_MASK, adj)
                    if neg {
                        aMan := mul(aMan, exp(BASE, sub(0, adj)))
                        bMan := mul(bMan, BASE_TO_THE_DIFF_76_L)
                    }
                    if iszero(neg) {
                        aMan := sdiv(aMan, exp(BASE, adj))
                        bMan := mul(bMan, BASE_TO_THE_DIFF_76_L)
                    }
                }
                // // if exponents are the same, we don't need to adjust the mantissas. We just set the result's exponent
                if eq(aExp, bExp) {
                    aMan := mul(aMan, BASE_TO_THE_DIFF_76_L)
                    bMan := mul(bMan, BASE_TO_THE_DIFF_76_L)
                    r := sub(aExp, shl(EXPONENT_BIT, DIGIT_DIFF_76_L))
                    sameExponent := 1
                }
            }
            // now we convert to 2's complement to carry out the operation
            if iszero(and(b, MANTISSA_SIGN_MASK)) {
                bMan := sub(0, bMan)
            }
            if and(a, MANTISSA_SIGN_MASK) {
                aMan := sub(0, aMan)
            }
            // now we can add/subtract
            addition := add(aMan, bMan)
            // encoding the unnormalized result
            if and(TWO_COMPLEMENT_SIGN_MASK, addition) {
                r := or(r, MANTISSA_SIGN_MASK) // assign the negative sign
                addition := sub(0, addition) // convert back from 2's complement
            }
            if iszero(addition) {
                r := 0
            }
        }
        // normalization
        if (packedFloat.unwrap(r) > 0) {
            uint rExp;
            assembly {
                rExp := shr(EXPONENT_BIT, r)
            }
            if (isSubtraction) {
                // subtraction case can have a number of digits anywhere from 1 to 76
                // we might get a normalized result, so we only normalize if necessary
                if (
                    !((addition <= MAX_M_DIGIT_NUMBER && addition >= MIN_M_DIGIT_NUMBER) ||
                        (addition <= MAX_L_DIGIT_NUMBER && addition >= MIN_L_DIGIT_NUMBER))
                ) {
                    uint digitsMantissa = findNumberOfDigits(addition);
                    assembly {
                        let mantissaReducer := sub(digitsMantissa, MAX_DIGITS_M)
                        let isResultL := slt(MAXIMUM_EXPONENT, add(sub(rExp, ZERO_OFFSET), mantissaReducer))
                        if isResultL {
                            mantissaReducer := sub(mantissaReducer, DIGIT_DIFF_L_M)
                            r := or(r, MANTISSA_L_FLAG_MASK)
                        }
                        let negativeReducer := and(TWO_COMPLEMENT_SIGN_MASK, mantissaReducer)
                        if negativeReducer {
                            addition := mul(addition, exp(BASE, sub(0, mantissaReducer)))
                            r := sub(r, shl(EXPONENT_BIT, sub(0, mantissaReducer)))
                        }
                        if iszero(negativeReducer) {
                            addition := div(addition, exp(BASE, mantissaReducer))
                            r := add(r, shl(EXPONENT_BIT, mantissaReducer))
                        }
                    }
                } else if (
                    addition >= MIN_L_DIGIT_NUMBER &&
                    rExp < (ZERO_OFFSET - uint(MAXIMUM_EXPONENT * -1) - DIGIT_DIFF_L_M)
                ) {
                    assembly {
                        addition := sdiv(addition, BASE_TO_THE_DIGIT_DIFF)
                        r := add(r, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                    }
                }
            } else {
                // addition case is simpler since it can only have 2 possibilities: same digits as its addends,
                // or + 1 digits due to an "overflow"
                assembly {
                    let isGreaterThan76Digits := gt(addition, MAX_76_DIGIT_NUMBER)
                    let maxExp := sub(
                        sub(sub(add(ZERO_OFFSET, MAXIMUM_EXPONENT), DIGIT_DIFF_L_M), DIGIT_DIFF_76_L),
                        isGreaterThan76Digits
                    )
                    let _isM := or(eq(rExp, maxExp), lt(rExp, maxExp))
                    if _isM {
                        addition := div(addition, BASE_TO_THE_MAX_DIGITS_M)
                        r := add(r, shl(EXPONENT_BIT, MAX_DIGITS_M))
                    }
                    if iszero(_isM) {
                        addition := div(addition, BASE_TO_THE_DIFF_76_L)
                        r := add(r, shl(EXPONENT_BIT, DIGIT_DIFF_76_L))
                        r := add(r, MANTISSA_L_FLAG_MASK)
                    }
                    if or(
                        gt(addition, MAX_L_DIGIT_NUMBER),
                        and(lt(addition, MIN_L_DIGIT_NUMBER), gt(addition, MAX_M_DIGIT_NUMBER))
                    ) {
                        addition := div(addition, BASE)
                        r := add(r, shl(EXPONENT_BIT, 1))
                    }
                }
            }
            assembly {
                r := or(r, addition)
            }
        }
    }

    /**
     * @dev gets the product of 2 signed floating point numbers
     * @param a the multiplicand
     * @param b the multiplier
     * @return r the result of a * b
     */
    function mul(packedFloat a, packedFloat b) internal pure returns (packedFloat r) {
        uint rMan;
        uint rExp;
        uint r0;
        uint r1;
        bool Loperation;
        if (packedFloat.unwrap(a) == 0 || packedFloat.unwrap(b) == 0) return packedFloat.wrap(0);
        assembly {
            let aL := gt(and(a, MANTISSA_L_FLAG_MASK), 0)
            let bL := gt(and(b, MANTISSA_L_FLAG_MASK), 0)
            Loperation := or(aL, bL)
            // we extract the exponent and mantissas for both
            let aExp := and(a, EXPONENT_MASK)
            let bExp := and(b, EXPONENT_MASK)
            let aMan := and(a, MANTISSA_MASK)
            let bMan := and(b, MANTISSA_MASK)

            if Loperation {
                // we make sure both of them are size L before continuing
                if iszero(aL) {
                    aMan := mul(aMan, BASE_TO_THE_DIGIT_DIFF)
                    aExp := sub(aExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                if iszero(bL) {
                    bMan := mul(bMan, BASE_TO_THE_DIGIT_DIFF)
                    bExp := sub(bExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                rExp := sub(add(shr(EXPONENT_BIT, aExp), shr(EXPONENT_BIT, bExp)), ZERO_OFFSET)
                let mm := mulmod(aMan, bMan, not(0))
                r0 := mul(aMan, bMan)
                r1 := sub(sub(mm, r0), lt(mm, r0))
            }
            if iszero(Loperation) {
                rMan := mul(aMan, bMan)
                rExp := sub(add(shr(EXPONENT_BIT, aExp), shr(EXPONENT_BIT, bExp)), ZERO_OFFSET)
            }
        }
        if (Loperation) {
            // MIN_L_DIGIT_NUMBER is equal to BASE ** (MAX_L_DIGITS - 1).
            // We avoid losing the lsd this way, but we could get 1 extra digit
            rMan = Uint512.div512x256(r0, r1, MIN_L_DIGIT_NUMBER);
            assembly {
                rExp := add(rExp, MAX_DIGITS_L_MINUS_1)
                let hasExtraDigit := gt(rMan, MAX_L_DIGIT_NUMBER)
                let maxExp := sub(sub(add(ZERO_OFFSET, MAXIMUM_EXPONENT), DIGIT_DIFF_L_M), hasExtraDigit)
                Loperation := gt(rExp, maxExp)
                // if not, we then know that it is a 2k-1-digit number
                if and(Loperation, hasExtraDigit) {
                    rMan := div(rMan, BASE)
                    rExp := add(rExp, 1)
                }
                if iszero(Loperation) {
                    if hasExtraDigit {
                        rMan := div(rMan, BASE_TO_THE_DIGIT_DIFF_PLUS_1)
                        rExp := add(rExp, DIGIT_DIFF_L_M_PLUS_1)
                    }
                    if iszero(hasExtraDigit) {
                        rMan := div(rMan, BASE_TO_THE_DIGIT_DIFF)
                        rExp := add(rExp, DIGIT_DIFF_L_M)
                    }
                }
            }
        } else {
            assembly {
                // multiplication between 2 numbers with k digits can result in a number between 2*k - 1 and 2*k digits
                // we check first if rMan is a 2k-digit number
                let is76digit := gt(rMan, MAX_75_DIGIT_NUMBER)
                let maxExp := add(
                    sub(sub(add(ZERO_OFFSET, MAXIMUM_EXPONENT), DIGIT_DIFF_L_M), DIGIT_DIFF_76_L),
                    iszero(is76digit)
                )
                Loperation := gt(rExp, maxExp)
                if is76digit {
                    if Loperation {
                        rMan := div(rMan, BASE_TO_THE_DIFF_76_L)
                        rExp := add(rExp, DIGIT_DIFF_76_L)
                    }
                    if iszero(Loperation) {
                        rMan := div(rMan, BASE_TO_THE_MAX_DIGITS_M)
                        rExp := add(rExp, MAX_DIGITS_M)
                    }
                }
                // if not, we then know that it is a 2k-1-digit number
                if iszero(is76digit) {
                    if Loperation {
                        rMan := div(rMan, BASE_TO_THE_DIFF_76_L_MINUS_1)
                        rExp := add(rExp, DIGIT_DIFF_76_L_MINUS_1)
                    }
                    if iszero(Loperation) {
                        rMan := div(rMan, BASE_TO_THE_MAX_DIGITS_M_MINUS_1)
                        rExp := add(rExp, MAX_DIGITS_M_MINUS_1)
                    }
                }
            }
        }
        assembly {
            r := or(xor(and(a, MANTISSA_SIGN_MASK), and(b, MANTISSA_SIGN_MASK)), or(rMan, shl(EXPONENT_BIT, rExp)))
            if Loperation {
                r := or(r, MANTISSA_L_FLAG_MASK)
            }
        }
    }

    /**
     * @dev gets the quotient of 2 signed floating point numbers
     * @param a the numerator
     * @param b the denominator
     * @return r the result of a / b
     */
    function div(packedFloat a, packedFloat b) internal pure returns (packedFloat r) {
        r = div(a, b, false);
    }

    /**
     * @dev gets the quotient of 2 signed floating point numbers which results in a large mantissa (72 digits) for better precision
     * @param a the numerator
     * @param b the denominator
     * @return r the result of a / b
     */
    function divL(packedFloat a, packedFloat b) internal pure returns (packedFloat r) {
        r = div(a, b, true);
    }

    /**
     * @dev gets the remainder of 2 signed floating point numbers
     * @param a the numerator
     * @param b the denominator
     * @param rL Large mantissa flag for the result. If true, the result will be force to use 72 digits for the mansitssa
     * @return r the result of a / b
     */
    function div(packedFloat a, packedFloat b, bool rL) internal pure returns (packedFloat r) {
        assembly {
            if eq(and(b, MANTISSA_MASK), 0) {
                let ptr := mload(0x40) // Get free memory pointer
                mstore(ptr, 0x08c379a000000000000000000000000000000000000000000000000000000000) // Selector for method Error(string)
                mstore(add(ptr, 0x04), 0x20) // String offset
                mstore(add(ptr, 0x24), 26) // Revert reason length
                mstore(add(ptr, 0x44), "float128: division by zero")
                revert(ptr, 0x64) // Revert data length is 4 bytes for selector and 3 slots of 0x20 bytes
            }
        }
        if (packedFloat.unwrap(a) == 0) return a;
        uint rMan;
        uint rExp;
        uint a0;
        uint a1;
        uint aMan;
        uint aExp;
        uint bMan;
        uint bExp;
        bool Loperation;
        assembly {
            let aL := gt(and(a, MANTISSA_L_FLAG_MASK), 0)
            let bL := gt(and(b, MANTISSA_L_FLAG_MASK), 0)
            // if a is zero then the result will be zero
            aMan := and(a, MANTISSA_MASK)
            aExp := shr(EXPONENT_BIT, and(a, EXPONENT_MASK))
            bMan := and(b, MANTISSA_MASK)
            bExp := shr(EXPONENT_BIT, and(b, EXPONENT_MASK))
            Loperation := or(
                or(rL, or(aL, bL)),
                // we add 1 to the calculation because division could result in an extra digit which will increase
                // the value of the exponent hence potentially violating maximum exponent
                sgt(add(sub(sub(sub(aExp, ZERO_OFFSET), MAX_DIGITS_M), sub(bExp, ZERO_OFFSET)), 1), MAXIMUM_EXPONENT)
            )

            if Loperation {
                if iszero(aL) {
                    aMan := mul(aMan, BASE_TO_THE_DIGIT_DIFF)
                    aExp := sub(aExp, DIGIT_DIFF_L_M)
                }
                if iszero(bL) {
                    bMan := mul(bMan, BASE_TO_THE_DIGIT_DIFF)
                    bExp := sub(bExp, DIGIT_DIFF_L_M)
                }
                let mm := mulmod(aMan, BASE_TO_THE_MAX_DIGITS_L, not(0))
                a0 := mul(aMan, BASE_TO_THE_MAX_DIGITS_L)
                a1 := sub(sub(mm, a0), lt(mm, a0))
                aExp := sub(aExp, MAX_DIGITS_L)
            }
            if iszero(Loperation) {
                // we add 38 more digits of precision
                aMan := mul(aMan, BASE_TO_THE_MAX_DIGITS_M)
                aExp := sub(aExp, MAX_DIGITS_M)
            }
        }
        if (Loperation) {
            rMan = Uint512.div512x256(a0, a1, bMan);
            unchecked {
                rExp = (aExp + ZERO_OFFSET) - bExp;
            }
        } else {
            assembly {
                rMan := div(aMan, bMan)
                rExp := sub(add(aExp, ZERO_OFFSET), bExp)
            }
        }
        assembly {
            if iszero(Loperation) {
                let hasExtraDigit := gt(rMan, MAX_M_DIGIT_NUMBER)
                if hasExtraDigit {
                    // we need to truncate the last digit
                    rExp := add(rExp, 1)
                    rMan := div(rMan, BASE)
                }
            }
            if Loperation {
                let hasExtraDigit := gt(rMan, MAX_L_DIGIT_NUMBER)
                let maxExp := sub(sub(add(ZERO_OFFSET, MAXIMUM_EXPONENT), DIGIT_DIFF_L_M), hasExtraDigit)
                Loperation := or(gt(rExp, maxExp), rL)
                if and(Loperation, hasExtraDigit) {
                    // we need to truncate the last digit
                    rExp := add(rExp, 1)
                    rMan := div(rMan, BASE)
                }
                if iszero(Loperation) {
                    if hasExtraDigit {
                        rExp := add(rExp, DIGIT_DIFF_L_M_PLUS_1)
                        rMan := div(rMan, BASE_TO_THE_DIGIT_DIFF_PLUS_1)
                    }
                    if iszero(hasExtraDigit) {
                        rExp := add(rExp, DIGIT_DIFF_L_M)
                        rMan := div(rMan, BASE_TO_THE_DIGIT_DIFF)
                    }
                }
            }
            r := or(xor(and(a, MANTISSA_SIGN_MASK), and(b, MANTISSA_SIGN_MASK)), or(rMan, shl(EXPONENT_BIT, rExp)))
            if Loperation {
                r := or(r, MANTISSA_L_FLAG_MASK)
            }
        }
    }

    /**
     * @dev get the square root of a signed floating point
     * @notice only positive numbers can have their square root calculated through this function
     * @param a the numerator to get the square root of
     * @return r the result of √a
     */
    function sqrt(packedFloat a) internal pure returns (packedFloat r) {
        uint s;
        int aExp;
        uint x;
        uint aMan;
        uint256 roundedDownResult;
        bool aL;
        assembly {
            if and(a, MANTISSA_SIGN_MASK) {
                let ptr := mload(0x40) // Get free memory pointer
                mstore(ptr, 0x08c379a000000000000000000000000000000000000000000000000000000000) // Selector for method Error(string)
                mstore(add(ptr, 0x04), 0x20) // String offset
                mstore(add(ptr, 0x24), 32) // Revert reason length
                mstore(add(ptr, 0x44), "float128: squareroot of negative")
                revert(ptr, 0x64) // Revert data length is 4 bytes for selector and 3 slots of 0x20 bytes
            }
            if iszero(a) {
                stop()
            }
            aL := gt(and(a, MANTISSA_L_FLAG_MASK), 0)
            aMan := and(a, MANTISSA_MASK)
            aExp := shr(EXPONENT_BIT, and(a, EXPONENT_MASK))
        }

        if (
            (aL && aExp > int(ZERO_OFFSET) - int(DIGIT_DIFF_L_M - 1)) ||
            (!aL && aExp > int(ZERO_OFFSET) - int(MAX_DIGITS_M / 2 - 1))
        ) {
            if (!aL) {
                aMan *= BASE_TO_THE_DIGIT_DIFF;
                aExp -= int(DIGIT_DIFF_L_M);
            }

            aExp -= int(ZERO_OFFSET);
            if (aExp % 2 != 0) {
                aMan *= BASE;
                --aExp;
            }
            (uint a0, uint a1) = Uint512.mul256x256(aMan, BASE_TO_THE_MAX_DIGITS_L);
            uint rMan = Uint512.sqrt512(a0, a1);
            int rExp = aExp - int(MAX_DIGITS_L);
            bool Lresult = true;
            unchecked {
                if (rMan > MAX_L_DIGIT_NUMBER) {
                    rMan /= BASE;
                    ++rExp;
                }
                rExp = (rExp) / 2;
                if (rExp <= MAXIMUM_EXPONENT - int(DIGIT_DIFF_L_M)) {
                    rMan /= BASE_TO_THE_DIGIT_DIFF;
                    rExp += int(DIGIT_DIFF_L_M);
                    Lresult = false;
                }
                rExp += int(ZERO_OFFSET);
            }
            assembly {
                r := or(or(shl(EXPONENT_BIT, rExp), rMan), mul(Lresult, MANTISSA_L_FLAG_MASK))
            }
        }
        // we need the exponent to be even so we can calculate the square root correctly
        else {
            assembly {
                if iszero(mod(aExp, 2)) {
                    if aL {
                        x := mul(aMan, BASE_TO_THE_DIFF_76_L)
                        aExp := sub(aExp, DIGIT_DIFF_76_L)
                    }
                    if iszero(aL) {
                        x := mul(aMan, BASE_TO_THE_MAX_DIGITS_M)
                        aExp := sub(aExp, MAX_DIGITS_M)
                    }
                }
                if mod(aExp, 2) {
                    if aL {
                        x := mul(aMan, BASE_TO_THE_DIFF_76_L_PLUS_1)
                        aExp := sub(aExp, DIGIT_DIFF_76_L_PLUS_1)
                    }
                    if iszero(aL) {
                        x := mul(aMan, BASE_TO_THE_MAX_DIGITS_M_PLUS_1)
                        aExp := sub(aExp, MAX_DIGITS_M_PLUS_1)
                    }
                }
                s := 1

                let xAux := x

                let cmp := or(
                    gt(xAux, 0x100000000000000000000000000000000),
                    eq(xAux, 0x100000000000000000000000000000000)
                )
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

                s := shr(1, add(div(x, s), s))
                s := shr(1, add(div(x, s), s))
                s := shr(1, add(div(x, s), s))
                s := shr(1, add(div(x, s), s))
                s := shr(1, add(div(x, s), s))
                s := shr(1, add(div(x, s), s))
                s := shr(1, add(div(x, s), s))

                roundedDownResult := div(x, s)
                if or(gt(s, roundedDownResult), eq(s, roundedDownResult)) {
                    s := roundedDownResult
                }

                // exponent should now be half of what it was
                aExp := add(div(sub(aExp, ZERO_OFFSET), 2), ZERO_OFFSET)
                // if we have extra digits, we know it comes from the extra digit to make the exponent even
                if gt(s, MAX_M_DIGIT_NUMBER) {
                    aExp := add(aExp, 1)
                    s := div(s, BASE)
                }
                // final encoding
                r := or(shl(EXPONENT_BIT, aExp), s)
            }
        }
    }

    /**
     * @dev performs a less than comparison
     * @param a the first term
     * @param b the second term
     * @return retVal the result of a < b
     */
    function lt(packedFloat a, packedFloat b) internal pure returns (bool retVal) {
        if (packedFloat.unwrap(a) == packedFloat.unwrap(b)) return false;
        assembly {
            let aL := gt(and(a, MANTISSA_L_FLAG_MASK), 0)
            let bL := gt(and(b, MANTISSA_L_FLAG_MASK), 0)
            let aNeg := gt(and(a, MANTISSA_SIGN_MASK), 0)
            let bNeg := gt(and(b, MANTISSA_SIGN_MASK), 0)
            let isAZero := iszero(a)
            let isBZero := iszero(b)
            let zeroFound := or(isAZero, isBZero)
            if zeroFound {
                if or(and(isAZero, iszero(bNeg)), and(isBZero, aNeg)) {
                    retVal := true
                }
            }
            if iszero(zeroFound) {
                let aExp := and(a, EXPONENT_MASK)
                let bExp := and(b, EXPONENT_MASK)
                let aMan := and(a, MANTISSA_MASK)
                let bMan := and(b, MANTISSA_MASK)
                if iszero(aL) {
                    aMan := mul(aMan, BASE_TO_THE_DIGIT_DIFF)
                    aExp := sub(aExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                if iszero(bL) {
                    bMan := mul(bMan, BASE_TO_THE_DIGIT_DIFF)
                    bExp := sub(bExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                if xor(aNeg, bNeg) {
                    retVal := aNeg
                }
                if and(iszero(aNeg), iszero(bNeg)) {
                    if eq(aExp, bExp) {
                        retVal := lt(aMan, bMan)
                    }
                    if lt(aExp, bExp) {
                        retVal := true
                    }
                }
                if and(aNeg, bNeg) {
                    if eq(aExp, bExp) {
                        retVal := gt(aMan, bMan)
                    }
                    if gt(aExp, bExp) {
                        retVal := true
                    }
                }
            }
        }
    }

    /**
     * @dev performs a less than or equals to comparison
     * @param a the first term
     * @param b the second term
     * @return retVal the result of a <= b
     */
    function le(packedFloat a, packedFloat b) internal pure returns (bool retVal) {
        if (packedFloat.unwrap(a) == packedFloat.unwrap(b)) return true;
        assembly {
            let aL := gt(and(a, MANTISSA_L_FLAG_MASK), 0)
            let bL := gt(and(b, MANTISSA_L_FLAG_MASK), 0)
            let aNeg := gt(and(a, MANTISSA_SIGN_MASK), 0)
            let bNeg := gt(and(b, MANTISSA_SIGN_MASK), 0)
            let isAZero := iszero(a)
            let isBZero := iszero(b)
            let zeroFound := or(isAZero, isBZero)
            if zeroFound {
                if or(and(isAZero, iszero(bNeg)), and(isBZero, aNeg)) {
                    retVal := true
                }
            }
            if iszero(zeroFound) {
                let aExp := and(a, EXPONENT_MASK)
                let bExp := and(b, EXPONENT_MASK)
                let aMan := and(a, MANTISSA_MASK)
                let bMan := and(b, MANTISSA_MASK)
                if iszero(aL) {
                    aMan := mul(aMan, BASE_TO_THE_DIGIT_DIFF)
                    aExp := sub(aExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                if iszero(bL) {
                    bMan := mul(bMan, BASE_TO_THE_DIGIT_DIFF)
                    bExp := sub(bExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                if xor(aNeg, bNeg) {
                    retVal := aNeg
                }
                if and(iszero(aNeg), iszero(bNeg)) {
                    if eq(aExp, bExp) {
                        retVal := lt(aMan, bMan)
                    }
                    if lt(aExp, bExp) {
                        retVal := true
                    }
                }
                if and(aNeg, bNeg) {
                    if eq(aExp, bExp) {
                        retVal := gt(aMan, bMan)
                    }
                    if gt(aExp, bExp) {
                        retVal := true
                    }
                }
            }
        }
    }

    /**
     * @dev performs a greater than comparison
     * @param a the first term
     * @param b the second term
     * @return retVal the result of a > b
     */
    function gt(packedFloat a, packedFloat b) internal pure returns (bool retVal) {
        if (packedFloat.unwrap(a) == packedFloat.unwrap(b)) return false;
        assembly {
            let aL := gt(and(a, MANTISSA_L_FLAG_MASK), 0)
            let bL := gt(and(b, MANTISSA_L_FLAG_MASK), 0)
            let aNeg := gt(and(a, MANTISSA_SIGN_MASK), 0)
            let bNeg := gt(and(b, MANTISSA_SIGN_MASK), 0)
            let isAZero := iszero(a)
            let isBZero := iszero(b)
            let zeroFound := or(isAZero, isBZero)
            if zeroFound {
                if or(and(isBZero, iszero(aNeg)), and(isAZero, bNeg)) {
                    retVal := true
                }
            }
            if iszero(zeroFound) {
                let aExp := and(a, EXPONENT_MASK)
                let bExp := and(b, EXPONENT_MASK)
                let aMan := and(a, MANTISSA_MASK)
                let bMan := and(b, MANTISSA_MASK)
                if iszero(aL) {
                    aMan := mul(aMan, BASE_TO_THE_DIGIT_DIFF)
                    aExp := sub(aExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                if iszero(bL) {
                    bMan := mul(bMan, BASE_TO_THE_DIGIT_DIFF)
                    bExp := sub(bExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                if xor(aNeg, bNeg) {
                    retVal := bNeg
                }
                if and(iszero(aNeg), iszero(bNeg)) {
                    if eq(aExp, bExp) {
                        retVal := lt(bMan, aMan)
                    }
                    if lt(bExp, aExp) {
                        retVal := true
                    }
                }
                if and(aNeg, bNeg) {
                    if eq(aExp, bExp) {
                        retVal := lt(aMan, bMan)
                    }
                    if lt(aExp, bExp) {
                        retVal := true
                    }
                }
            }
        }
    }

    /**
     * @dev performs a greater than or equal to comparison
     * @param a the first term
     * @param b the second term
     * @return retVal the result of a >= b
     */
    function ge(packedFloat a, packedFloat b) internal pure returns (bool retVal) {
        if (packedFloat.unwrap(a) == packedFloat.unwrap(b)) return true;
        assembly {
            let aL := gt(and(a, MANTISSA_L_FLAG_MASK), 0)
            let bL := gt(and(b, MANTISSA_L_FLAG_MASK), 0)
            let aNeg := gt(and(a, MANTISSA_SIGN_MASK), 0)
            let bNeg := gt(and(b, MANTISSA_SIGN_MASK), 0)
            let isAZero := iszero(a)
            let isBZero := iszero(b)
            let zeroFound := or(isAZero, isBZero)
            if zeroFound {
                if or(and(isBZero, iszero(aNeg)), and(isAZero, bNeg)) {
                    retVal := true
                }
            }
            if iszero(zeroFound) {
                let aExp := and(a, EXPONENT_MASK)
                let bExp := and(b, EXPONENT_MASK)
                let aMan := and(a, MANTISSA_MASK)
                let bMan := and(b, MANTISSA_MASK)
                if iszero(aL) {
                    aMan := mul(aMan, BASE_TO_THE_DIGIT_DIFF)
                    aExp := sub(aExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                if iszero(bL) {
                    bMan := mul(bMan, BASE_TO_THE_DIGIT_DIFF)
                    bExp := sub(bExp, shl(EXPONENT_BIT, DIGIT_DIFF_L_M))
                }
                if xor(aNeg, bNeg) {
                    retVal := bNeg
                }
                if and(iszero(aNeg), iszero(bNeg)) {
                    if eq(aExp, bExp) {
                        retVal := lt(bMan, aMan)
                    }
                    if lt(bExp, aExp) {
                        retVal := true
                    }
                }
                if and(aNeg, bNeg) {
                    if eq(aExp, bExp) {
                        retVal := lt(aMan, bMan)
                    }
                    if lt(aExp, bExp) {
                        retVal := true
                    }
                }
            }
        }
    }

    /**
     * @dev performs an equality comparison
     * @param a the first term
     * @param b the second term
     * @return retVal the result of a == b
     */
    function eq(packedFloat a, packedFloat b) internal pure returns (bool retVal) {
        retVal = packedFloat.unwrap(a) == packedFloat.unwrap(b);
    }

    /**
     * @dev encodes a pair of signed integer values describing a floating point number into a packedFloat
     * Examples: 1234.567 can be expressed as: 123456 x 10**(-3), or 1234560 x 10**(-4), or 12345600 x 10**(-5), etc.
     * @notice the mantissa can hold a maximum of 38 or 72 digits. Any number in between or more digits will lose precision.
     * @param mantissa the integer that holds the mantissa digits (38 or 72 digits max)
     * @param exponent the exponent of the floating point number (between -8192 and +8191)
     * @return float the encoded number. This value will ocupy a single 256-bit word and will hold the normalized
     * version of the floating-point number (shifts the exponent enough times to have exactly 38 or 72 significant digits)
     */
    function toPackedFloat(int mantissa, int exponent) internal pure returns (packedFloat float) {
        uint digitsMantissa;
        uint mantissaMultiplier;
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
                !((mantissa <= int(MAX_M_DIGIT_NUMBER) && mantissa >= int(MIN_M_DIGIT_NUMBER)) ||
                    (mantissa <= int(MAX_L_DIGIT_NUMBER) && mantissa >= int(MIN_L_DIGIT_NUMBER)))
            ) {
                digitsMantissa = findNumberOfDigits(uint(mantissa));
                assembly {
                    mantissaMultiplier := sub(digitsMantissa, MAX_DIGITS_M)
                    let isResultL := slt(MAXIMUM_EXPONENT, add(exponent, mantissaMultiplier))
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
                (mantissa <= int(MAX_M_DIGIT_NUMBER) && mantissa >= int(MIN_M_DIGIT_NUMBER)) &&
                exponent > MAXIMUM_EXPONENT
            ) {
                assembly {
                    mantissa := mul(mantissa, BASE_TO_THE_DIGIT_DIFF)
                    exponent := sub(exponent, DIGIT_DIFF_L_M)
                    float := add(float, MANTISSA_L_FLAG_MASK)
                }
            } else if ((mantissa <= int(MAX_L_DIGIT_NUMBER) && mantissa >= int(MIN_L_DIGIT_NUMBER))) {
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

    /**
     * @dev decodes a packedFloat into its mantissa and its exponent
     * @param float the floating-point number expressed as a packedFloat to decode
     * @return mantissa the 38 mantissa digits of the floating-point number
     * @return exponent the exponent of the floating-point number
     */
    function decode(packedFloat float) internal pure returns (int mantissa, int exponent) {
        assembly {
            // exponent
            let _exp := shr(EXPONENT_BIT, float)
            if gt(ZERO_OFFSET, _exp) {
                exponent := sub(0, sub(ZERO_OFFSET, _exp))
            }
            if gt(_exp, ZERO_OFFSET_MINUS_1) {
                exponent := sub(_exp, ZERO_OFFSET)
            }
            // mantissa
            mantissa := and(float, MANTISSA_MASK)
            /// we use 2's complement for mantissa sign
            if and(float, MANTISSA_SIGN_MASK) {
                mantissa := sub(0, mantissa)
            }
        }
    }

    /**
     * @dev finds the amount of digits of a number
     * @param x the number
     * @return log the amount of digits of x
     */
    function findNumberOfDigits(uint x) internal pure returns (uint log) {
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
