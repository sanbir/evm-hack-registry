// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {packedFloat} from "./Types.sol";
import {Float128} from "./Float128.sol";

/**
 * @title Natural Logarithm Floating-Point Library
 * @dev the library uses the type packedFloat whih is a uint under the hood
 * @author Inspired by a Python proposal by @miguel-ot and @neel-thrackle, and refined/implemented in Solidity by @oscarsernarosero @PmpetersoCode55 @VoR0220
 */

library Ln {
    using Float128 for packedFloat;

    // These constants are used in an inline assembly block and must direct number constants
    uint constant MANTISSA_MASK = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    uint constant MANTISSA_L_FLAG_MASK = 0x2000000000000000000000000000000000000000000000000000000000000;
    uint constant EXPONENT_MASK = 0xfffc000000000000000000000000000000000000000000000000000000000000;
    uint constant ZERO_OFFSET = 8192;
    uint constant EXPONENT_BIT = 242;

    // ln specific variables

    // ln(2) from Wolfram
    // 0.6931471805599453094172321214581765680755001343602552541206800094933936219696947

    // ln(1.1) from Wolfram
    // 0.095310179804324860043952123280765092220605365308644199185239808163001014

    int constant ln10_70 = 23025850929940456840179914546843642076011014886287729760333279009675726;
    int constant ln2_70 = 6931471805599453094172321214581765680755001343602552541206800094933936;
    int constant ln1dot1_70 = 953101798043248600439521232807650922206053653086441991852398081630010;
    int constant ln1dot01_70 = 99503308531680828482153575442607416886796099400587978646095597668666;
    int constant ln1dot001_70 = 9995003330835331668093989205350114607550623931665519970196668289003;

    // ln10, ln2 and ln1.1 represented as integers with M significant digits
    int constant ln10_M = ln10_70 / int(10 ** (uint(70 - Float128.MAX_DIGITS_M + 1)));
    int constant ln2_M = ln2_70 / int(10 ** (uint(70 - Float128.MAX_DIGITS_M)));
    int constant ln1dot1_M = ln1dot1_70 / int(10 ** (uint(70 - Float128.MAX_DIGITS_M - 1)));
    int constant ln1dot01_M = ln1dot01_70 / int(10 ** (uint(70 - Float128.MAX_DIGITS_M - 2)));
    int constant ln1dot001_M = ln1dot001_70 / int(10 ** (uint(70 - Float128.MAX_DIGITS_M - 3)));

    // ln10, ln2 and ln1.1 represented as float128
    packedFloat constant ln10 =
        packedFloat.wrap(57634551253070896831007164474234001986315550567012630870766974200712100735196);
    packedFloat constant ln2 =
        packedFloat.wrap(57627483864811783293688831284231030312298529498551182469036031073505904270823);
    packedFloat constant ln1dot1 =
        packedFloat.wrap(57620416476552669756370498094228058638261215024712010322305773559835681227132);
    packedFloat constant ln1dot01 =
        packedFloat.wrap(57613349088293556219052164904225086964202098217851863814911488587192353072694);
    packedFloat constant ln1dot001 =
        packedFloat.wrap(57606281700034442681733831714222115290139235007041033827277788478998076322779);

    // Natural Logs functions
    /**
     * @dev determine the natural log of the input
     * @param input the number of which to derive the natural log.
     * @return result log of the input as a packedFloat
     * @notice passing a large-mantissa input will have better precision results.
     */
    function ln(packedFloat input) public pure returns (packedFloat result) {
        uint mantissa;
        int exponent;
        bool inputL;
        assembly {
            inputL := gt(and(input, MANTISSA_L_FLAG_MASK), 0)
            mantissa := and(input, MANTISSA_MASK)
            exponent := sub(shr(EXPONENT_BIT, and(input, EXPONENT_MASK)), ZERO_OFFSET)
        }
        if (
            exponent == 0 - int(inputL ? Float128.MAX_DIGITS_L_MINUS_1 : Float128.MAX_DIGITS_M_MINUS_1) &&
            mantissa == (inputL ? Float128.MIN_L_DIGIT_NUMBER : Float128.MIN_M_DIGIT_NUMBER)
        ) return packedFloat.wrap(0);
        result = ln_helper(mantissa, exponent, inputL);
    }

    /**
     * @dev Natural Log Helper function
     * @param mantissa the integer that holds the mantissa digits (38 digits max)
     * @param exp the exponent of the floating point number (between -8192 and +8191)
     * @param inputL use positive exponent
     * @return result the log of the input from ln function
     */
    function ln_helper(uint mantissa, int exp, bool inputL) private pure returns (packedFloat result) {
        int positiveExp = exp * -1;
        if (
            (inputL && int(Float128.MAX_DIGITS_L) > positiveExp) ||
            (!inputL && int(Float128.MAX_DIGITS_M) > positiveExp)
        ) {
            if (inputL) {
                mantissa /= Float128.BASE_TO_THE_DIGIT_DIFF;
                exp += int(Float128.DIGIT_DIFF_L_M);
            }

            uint q1 = Float128.BASE_TO_THE_MAX_DIGITS_M_X_2 / mantissa;
            uint r1 = Float128.BASE_TO_THE_MAX_DIGITS_M_X_2 % mantissa;
            uint q2 = (Float128.BASE_TO_THE_MAX_DIGITS_M * r1) / mantissa;
            uint one_over_argument_in_long_int = q1 * Float128.BASE_TO_THE_MAX_DIGITS_M + q2;
            uint m10 = one_over_argument_in_long_int > Float128.MAX_76_DIGIT_NUMBER ? 77 : 76;

            uint one_over_arguments_76 = one_over_argument_in_long_int;
            uint m76 = m10;
            m76 -= Float128.DIGIT_DIFF_76_L;
            one_over_arguments_76 /= Float128.BASE_TO_THE_DIFF_76_L;
            if (m76 > Float128.MAX_DIGITS_L) {
                --m76;
                one_over_arguments_76 /= Float128.BASE;
            }
            int exp_one_over_argument = 0 - int(Float128.MAX_DIGITS_M) - int(Float128.MAX_DIGITS_M_X_2) - exp;
            packedFloat a = packedFloat.wrap(0).sub(
                ln(Float128.toPackedFloat(int(one_over_arguments_76), 0 - int(m76)))
            );
            result = a.sub(Float128.toPackedFloat((exp_one_over_argument + int(m10)), 0).mul(ln10));
        } else {
            int256 m10 = inputL ? int(Float128.MAX_DIGITS_L) + exp : int(Float128.MAX_DIGITS_M) + exp;
            exp -= m10;

            mantissa *= (inputL ? Float128.BASE_TO_THE_DIFF_76_L : Float128.BASE_TO_THE_MAX_DIGITS_M);
            exp -= int(inputL ? Float128.DIGIT_DIFF_L_M : Float128.MAX_DIGITS_M);

            uint256 k;
            uint256 multiplier_k;
            if (mantissa > (25 * (10 ** 74))) {
                if (mantissa > (50 * (10 ** 74))) {
                    multiplier_k = 1;
                } else {
                    k = 1;
                    multiplier_k = 2;
                }
            } else {
                if (mantissa > (125 * 10 ** 73)) {
                    k = 2;
                    multiplier_k = 4;
                } else {
                    k = 3;
                    multiplier_k = 8;
                }
            }
            mantissa *= multiplier_k;
            uint uMantissa = mantissa;

            uint256 q1;
            (q1, uMantissa) = calculateQ1(uMantissa);

            // We find the suitable value of q2 and the multiplier (1.014)**q2
            // so that 0.986 <= (1.014)**q2 * updated_x <= 1
            // We use the following intervals:
            // (index -> lower bound of the interval)
            // 0 ->  9 * 10**75
            // 1 ->  9072 * 10**72
            // 2 ->  9199 * 10**72
            // 3 ->  9328 * 10**72
            // 4 ->  9459 * 10**72
            // 5 ->  9591 * 10**72
            // 6 ->  9725 * 10**72
            // 7 ->  9860 * 10**72
            // partition_1014 = [0.9, 0.9072, 0.9199, 0.9328, 0.9459, 0.9591, 0.9725, 0.986, 1]

            uint256 q2;
            (q2, uMantissa) = calculateQ2(uMantissa);

            // We find the suitable value of q3 and the multiplier (1.0013)**q3
            // so that 0.9949 <= (1.0013)**q3 * updated_x <= 1
            // We use the following intervals:
            // (index -> lower bound of the interval)
            // 0 ->  986 * 10**73
            // 1 ->  987274190490 * 10**64
            // 2 ->  988557646937 * 10**64
            // 3 ->  989842771878 * 10**64
            // 4 ->  991129567482 * 10**64
            // 5 ->  992418035920 * 10**64
            // 6 ->  993708179366 * 10**64
            // 7 ->  995 * 10**73
            // partition_10013 = [0.986, 0.987274190490, 0.988557646937, 0.989842771878, 0.991129567482, 0.992418035920, 0.993708179366, 0.995, 1]

            uint256 q3;
            (q3, uMantissa) = calculateQ3(uMantissa);

            result = intermediateTermAddition(result, k, q1, q2, q3, m10, uMantissa);
        }
    }

    /**
     * @dev Intermediate Addition Helper
     * @param result the result from the calling ln()
     * @param k value passed from ln
     * @param q1 BASE_TO_THE_MAX_DIGITS_M_X_2 / mantissa
     * @param q2 (BASE_TO_THE_MAX_DIGITS_M * r1) / mantissa
     * @param q3 value returned from calculateQ3 function
     * @param m10 one_over_argument_in_long_int > MAX_76_DIGIT_NUMBER ? 77 : 76;
     * @param mantissa the 38 mantissa digits of the floating-point number
     * @return finalResult Log of the input from ln function
     */
    function intermediateTermAddition(
        packedFloat result,
        uint256 k,
        uint256 q1,
        uint256 q2,
        uint256 q3,
        int256 m10,
        uint256 mantissa
    ) private pure returns (packedFloat finalResult) {
        // Now digits has already been updated
        int z_int = 10 ** 76 - int(mantissa);
        int len_z_int = int(Float128.findNumberOfDigits(uint(z_int)));
        if (z_int != 0) {
            int diff = len_z_int - 38;
            z_int = diff < 0 ? int(uint(z_int) * 10 ** uint(diff * -1)) : int(uint(z_int) / 10 ** uint(diff));
        }

        packedFloat z = Float128.toPackedFloat(z_int, (len_z_int - 76 - 38));

        // Number of terms of the Taylor series:
        int terms = 15;
        result = z;
        packedFloat z_to_j = z;
        for (uint j = 2; j < uint(terms + 1); j++) {
            z_to_j = z_to_j.mul(z);
            result = result.add(z_to_j.div(Float128.toPackedFloat(int(j), int(0))));
        }

        packedFloat lnB = Float128.toPackedFloat(13902905168991420865477877458246859530, -39);
        packedFloat lnC = Float128.toPackedFloat(12991557316200501157605555658804528711, -40);

        finalResult = finalTermAddition(result, k, q1, q2, q3, m10, lnB, lnC);
    }

    /**
     * @dev Final Addition Helper Function
     * @param result the result from the calling ln()
     * @param k value passed from ln
     * @param q1 BASE_TO_THE_MAX_DIGITS_M_X_2 / mantissa
     * @param q2 (BASE_TO_THE_MAX_DIGITS_M * r1) / mantissa
     * @param q3 value returned from calculateQ3 function
     * @param m10 one_over_argument_in_long_int > MAX_76_DIGIT_NUMBER ? 77 : 76
     * @param lnB toPackedFloat(13902905168991420865477877458246859530, -39)
     * @param lnC toPackedFloat(12991557316200501157605555658804528711, -40)
     */
    function finalTermAddition(
        packedFloat result,
        uint256 k,
        uint256 q1,
        uint256 q2,
        uint256 q3,
        int256 m10,
        packedFloat lnB,
        packedFloat lnC
    ) private pure returns (packedFloat finalResult) {
        packedFloat firstTerm = result.add(Float128.toPackedFloat(int(k), 0).mul(ln2));

        packedFloat secondTerm = firstTerm.add(Float128.toPackedFloat(int(q1), 0).mul(ln1dot1));

        packedFloat thirdTerm = secondTerm.add(Float128.toPackedFloat(int(q2), 0).mul(lnB));

        packedFloat fourthTerm = thirdTerm.add(Float128.toPackedFloat(int(q3), 0).mul(lnC));

        packedFloat fifthTerm = fourthTerm.sub(Float128.toPackedFloat(int(m10), 0).mul(ln10));

        finalResult = fifthTerm.mul(Float128.toPackedFloat(-1, 0));
    }

    /**
     * @dev Helper function to calculate q1 in LN function
     * @param mantissa the 38 mantissa digits of the floating-point number
     * @return q1 uint value of q1
     * @return updatedMantissa updated mantissa for q1
     */
    function calculateQ1(uint256 mantissa) public pure returns (uint256 q1, uint256 updatedMantissa) {
        if (mantissa > (68300000 * 10 ** 68)) {
            if (mantissa > (82000000 * 10 ** 68)) {
                if (mantissa > (90000000 * 10 ** 68)) {
                    q1 = 0;
                    // multiplier_q1
                    updatedMantissa = mantissa;
                } else {
                    q1 = 1;
                    updatedMantissa = mantissa + mantissa / 10;
                }
            } else {
                if (mantissa > (75000000 * 10 ** 68)) {
                    q1 = 2;
                    updatedMantissa = mantissa + (2 * mantissa) / 10 + mantissa / 100;
                } else {
                    q1 = 3;
                    updatedMantissa = mantissa + (3 * mantissa) / 10 + (3 * mantissa) / 100 + mantissa / 1000;
                }
            }
        } else {
            if (mantissa > (56400000 * 10 ** 68)) {
                if (mantissa > (62000000 * 10 ** 68)) {
                    q1 = 4;
                    updatedMantissa =
                        mantissa +
                        (4 * mantissa) /
                        10 +
                        (6 * mantissa) /
                        100 +
                        (4 * mantissa) /
                        1000 +
                        mantissa /
                        10000;
                } else {
                    q1 = 5;
                    updatedMantissa =
                        mantissa +
                        (6 * mantissa) /
                        10 +
                        (1 * mantissa) /
                        100 +
                        (5 * mantissa) /
                        10000 +
                        (1 * mantissa) /
                        100000;
                }
            } else {
                if (mantissa > (51200000 * 10 ** 68)) {
                    q1 = 6;
                    updatedMantissa =
                        mantissa +
                        (7 * mantissa) /
                        10 +
                        (7 * mantissa) /
                        100 +
                        (1 * mantissa) /
                        1000 +
                        (5 * mantissa) /
                        10000 +
                        (6 * mantissa) /
                        100000 +
                        (1 * mantissa) /
                        1000000;
                } else {
                    q1 = 7;
                    // multiplier_q1 = 1.1 ** 7 # = 1.9487171
                    updatedMantissa =
                        mantissa +
                        (9 * mantissa) /
                        10 +
                        (4 * mantissa) /
                        100 +
                        (8 * mantissa) /
                        1000 +
                        (7 * mantissa) /
                        10000 +
                        (1 * mantissa) /
                        100000 +
                        (7 * mantissa) /
                        1000000 +
                        (1 * mantissa) /
                        10000000;
                }
            }
        }
    }

    /**
     * @dev Helper function to calculate q2 in LN function
     * @param mantissa the 38 mantissa digits of the floating-point number
     * @return q2 uint value of q2
     * @return updatedMantissa updated mantissa for q2
     */
    function calculateQ2(uint256 mantissa) public pure returns (uint256 q2, uint256 updatedMantissa) {
        if (mantissa > (9459 * 10 ** 72)) {
            if (mantissa > (9725 * 10 ** 72)) {
                if (mantissa > 9860 * 10 ** 72) {
                    q2 = 0;
                    // multiplier_q2 = 1
                    updatedMantissa = mantissa;
                } else {
                    q2 = 1;
                    updatedMantissa = mantissa + (1 * mantissa) / 100 + (4 * mantissa) / 1000;
                }
            } else {
                if (mantissa > (9591 * 10 ** 72)) {
                    q2 = 2;
                    // multiplier_q2 = 1.028196
                    updatedMantissa =
                        mantissa +
                        (2 * mantissa) /
                        100 +
                        (8 * mantissa) /
                        1000 +
                        (1 * mantissa) /
                        10000 +
                        (9 * mantissa) /
                        100000 +
                        (6 * mantissa) /
                        1000000;
                } else {
                    q2 = 3;
                    // multiplier_q2 = 1.042590744
                    updatedMantissa =
                        mantissa +
                        (4 * mantissa) /
                        100 +
                        (2 * mantissa) /
                        1000 +
                        (5 * mantissa) /
                        10000 +
                        (9 * mantissa) /
                        100000 +
                        (0 * mantissa) /
                        1000000 +
                        (7 * mantissa) /
                        10000000 +
                        (4 * mantissa) /
                        100000000 +
                        (4 * mantissa) /
                        1000000000;
                }
            }
        } else {
            if (mantissa > (9199 * 10 ** 72)) {
                if (mantissa > (9328 * 10 ** 72)) {
                    q2 = 4;
                    // multiplier_q2 = 1.057187014416
                    updatedMantissa =
                        mantissa +
                        (5 * mantissa) /
                        100 +
                        (7 * mantissa) /
                        1000 +
                        (1 * mantissa) /
                        10000 +
                        (8 * mantissa) /
                        100000 +
                        (7 * mantissa) /
                        1000000 +
                        (0 * mantissa) /
                        10000000 +
                        (1 * mantissa) /
                        100000000 +
                        (4 * mantissa) /
                        1000000000 +
                        (4 * mantissa) /
                        10000000000 +
                        (1 * mantissa) /
                        100000000000 +
                        (6 * mantissa) /
                        1000000000000;
                } else {
                    q2 = 5;
                    // multiplier_q2 = 1.071987632617824
                    // updatedMantissa = mantissa + 7 * mantissa / 100 + 1 * mantissa / 1000
                    //                 + 9 * mantissa / 10000 + 8 * mantissa / 100000 + 7 * mantissa / 1000000
                    //                 + 6 * mantissa / 10000000 + 3 * mantissa / 100000000 + 2 * mantissa / 1000000000
                    //                 + 6 * mantissa / 10000000000 + 1 * mantissa / 100000000000 + 7 * mantissa / 1000000000000
                    //                 + 8 * mantissa / 10000000000000 + 2 * mantissa / 100000000000000 + 4 * mantissa / 1000000000000000;
                    assembly {
                        // Start with the base value
                        updatedMantissa := mantissa

                        // 7 * mantissa / 100
                        updatedMantissa := add(updatedMantissa, div(mul(7, mantissa), 100))

                        // 1 * mantissa / 1000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 1000))

                        // 9 * mantissa / 10000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 10000))

                        // 8 * mantissa / 100000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 100000))

                        // 7 * mantissa / 1000000
                        updatedMantissa := add(updatedMantissa, div(mul(7, mantissa), 1000000))

                        // 6 * mantissa / 10000000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 10000000))

                        // 3 * mantissa / 100000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 100000000))

                        // 2 * mantissa / 1000000000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 1000000000))

                        // 6 * mantissa / 10000000000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 10000000000))

                        // 1 * mantissa / 100000000000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 100000000000))

                        // 7 * mantissa / 1000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(7, mantissa), 1000000000000))

                        // 8 * mantissa / 10000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 10000000000000))

                        // 2 * mantissa / 100000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 100000000000000))

                        // 4 * mantissa / 1000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(4, mantissa), 1000000000000000))
                    }
                }
            } else {
                if (mantissa > (9072 * 10 ** 72)) {
                    q2 = 6;
                    // multiplier_q2 = 1.086995459474473536
                    // updatedMantissa = mantissa + 8 * mantissa / 100 + 6 * mantissa / 1000
                    //             + 9 * mantissa / 10000 + 9 * mantissa / 100000 + 5 * mantissa / 1000000
                    //             + 4 * mantissa / 10000000 + 5 * mantissa / 100000000 + 9 * mantissa / 1000000000
                    //             + 4 * mantissa / 10000000000 + 7 * mantissa / 100000000000 + 4 * mantissa / 1000000000000
                    //             + 4 * mantissa / 10000000000000 + 7 * mantissa / 100000000000000 + 3 * mantissa / 1000000000000000
                    //             + 5 * mantissa / 10000000000000000 + 3 * mantissa / 100000000000000000 + 6 * mantissa / 1000000000000000000;
                    assembly {
                        // Start with the base value
                        updatedMantissa := mantissa

                        // 8 * mantissa / 100
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 100))

                        // 6 * mantissa / 1000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 1000))

                        // 9 * mantissa / 10000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 10000))

                        // 9 * mantissa / 100000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 100000))

                        // 5 * mantissa / 1000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 1000000))

                        // 4 * mantissa / 10000000
                        updatedMantissa := add(updatedMantissa, div(mul(4, mantissa), 10000000))

                        // 5 * mantissa / 100000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 100000000))

                        // 9 * mantissa / 1000000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 1000000000))

                        // 4 * mantissa / 10000000000
                        updatedMantissa := add(updatedMantissa, div(mul(4, mantissa), 10000000000))

                        // 7 * mantissa / 100000000000
                        updatedMantissa := add(updatedMantissa, div(mul(7, mantissa), 100000000000))

                        // 4 * mantissa / 1000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(4, mantissa), 1000000000000))

                        // 4 * mantissa / 10000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(4, mantissa), 10000000000000))

                        // 7 * mantissa / 100000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(7, mantissa), 100000000000000))

                        // 3 * mantissa / 1000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 1000000000000000))

                        // 5 * mantissa / 10000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 10000000000000000))

                        // 3 * mantissa / 100000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 100000000000000000))

                        // 6 * mantissa / 1000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 1000000000000000000))
                    }
                } else {
                    q2 = 7;
                    // multiplier_q2 = 1.102213395907116165504
                    // updatedMantissa = mantissa + 1 * mantissa / 10 + 2 * mantissa / 1000
                    //         + 2 * mantissa / 10000 + 1 * mantissa / 100000 + 3 * mantissa / 1000000
                    //         + 3 * mantissa / 10000000 + 9 * mantissa / 100000000 + 5 * mantissa / 1000000000
                    //         + 9 * mantissa / 10000000000 + 7 * mantissa / 1000000000000
                    //         + 1 * mantissa / 10000000000000 + 1 * mantissa / 100000000000000 + 6 * mantissa / 1000000000000000
                    //         + 1 * mantissa / 10000000000000000 + 6 * mantissa / 100000000000000000 + 5 * mantissa / 1000000000000000000
                    //         + 5 * mantissa / 10000000000000000000 + 4 * mantissa / 1000000000000000000000;
                    assembly {
                        // Start with the base value
                        updatedMantissa := mantissa

                        // 1 * mantissa / 10
                        updatedMantissa := add(updatedMantissa, div(mantissa, 10))

                        // 2 * mantissa / 1000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 1000))

                        // 2 * mantissa / 10000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 10000))

                        // 1 * mantissa / 100000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 100000))

                        // 3 * mantissa / 1000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 1000000))

                        // 3 * mantissa / 10000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 10000000))

                        // 9 * mantissa / 100000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 100000000))

                        // 5 * mantissa / 1000000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 1000000000))

                        // 9 * mantissa / 10000000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 10000000000))

                        // 7 * mantissa / 1000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(7, mantissa), 1000000000000))

                        // 1 * mantissa / 10000000000000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 10000000000000))

                        // 1 * mantissa / 100000000000000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 100000000000000))

                        // 6 * mantissa / 1000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 1000000000000000))

                        // 1 * mantissa / 10000000000000000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 10000000000000000))

                        // 6 * mantissa / 100000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 100000000000000000))

                        // 5 * mantissa / 1000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 1000000000000000000))

                        // 5 * mantissa / 10000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 10000000000000000000))

                        // 4 * mantissa / 1000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(4, mantissa), 1000000000000000000000))
                    }
                }
            }
        }
    }

    /**
     * @dev Helper function to calculate q3 in LN function
     * @param mantissa the 38 mantissa digits of the floating-point number
     * @return q3 uint value of q3
     * @return updatedMantissa updated mantissa for q3
     */
    function calculateQ3(uint256 mantissa) public pure returns (uint256 q3, uint256 updatedMantissa) {
        if (mantissa > (991129567482 * 10 ** 64)) {
            if (mantissa > (993708179366 * 10 ** 64)) {
                if (mantissa > (995 * 10 ** 73)) {
                    q3 = 0;
                    // multiplier_q3 = 1
                    updatedMantissa = mantissa;
                } else {
                    q3 = 1;
                    // multiplier_q3 = 1.0013
                    updatedMantissa = mantissa + (1 * mantissa) / 1000 + (3 * mantissa) / 10000;
                }
            } else {
                if (mantissa > (992418035920 * 10 ** 64)) {
                    q3 = 2;
                    // multiplier_q3 = 1.00260169
                    updatedMantissa =
                        mantissa +
                        (2 * mantissa) /
                        1000 +
                        (6 * mantissa) /
                        10000 +
                        (1 * mantissa) /
                        1000000 +
                        (6 * mantissa) /
                        10000000 +
                        (9 * mantissa) /
                        100000000;
                } else {
                    q3 = 3;
                    // multiplier_q3 = 1.003905072197
                    updatedMantissa =
                        mantissa +
                        (3 * mantissa) /
                        1000 +
                        (9 * mantissa) /
                        10000 +
                        (5 * mantissa) /
                        1000000 +
                        (7 * mantissa) /
                        100000000 +
                        (2 * mantissa) /
                        1000000000 +
                        (1 * mantissa) /
                        10000000000 +
                        (9 * mantissa) /
                        100000000000 +
                        (7 * mantissa) /
                        1000000000000;
                }
            }
        } else {
            if (mantissa > (988557646937 * 10 ** 64)) {
                if (mantissa > (989842771878 * 10 ** 64)) {
                    q3 = 4;
                    // multiplier_q3 = 1.0052101487908561
                    // updatedMantissa = mantissa + 5 * mantissa / 1000 + 2 * mantissa / 10000
                    //             + 1 * mantissa / 100000 + 1 * mantissa / 10000000 + 4 * mantissa / 100000000
                    //             + 8 * mantissa / 1000000000 + 7 * mantissa / 10000000000 + 9 * mantissa / 100000000000
                    //             + 8 * mantissa / 10000000000000 + 5 * mantissa / 100000000000000 + 6 * mantissa / 1000000000000000 + 1 * mantissa / 10000000000000000;
                    assembly {
                        // Start with the base value
                        updatedMantissa := mantissa

                        // 5 * mantissa / 1000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 1000))

                        // 2 * mantissa / 10000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 10000))

                        // 1 * mantissa / 100000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 100000))

                        // 1 * mantissa / 10000000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 10000000))

                        // 4 * mantissa / 100000000
                        updatedMantissa := add(updatedMantissa, div(mul(4, mantissa), 100000000))

                        // 8 * mantissa / 1000000000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 1000000000))

                        // 7 * mantissa / 10000000000
                        updatedMantissa := add(updatedMantissa, div(mul(7, mantissa), 10000000000))

                        // 9 * mantissa / 100000000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 100000000000))

                        // 8 * mantissa / 10000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 10000000000000))

                        // 5 * mantissa / 100000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 100000000000000))

                        // 6 * mantissa / 1000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 1000000000000000))

                        // 1 * mantissa / 10000000000000000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 10000000000000000))
                    }
                } else {
                    q3 = 5;
                    // multiplier_q3 = 1.00651692198428421293
                    // updatedMantissa = mantissa + 6 * mantissa / 1000 + 5 * mantissa / 10000
                    //             + 1 * mantissa / 100000 + 6 * mantissa / 1000000 + 9 * mantissa / 10000000 + 2 * mantissa / 100000000
                    //             + 1 * mantissa / 1000000000 + 9 * mantissa / 10000000000 + 8 * mantissa / 100000000000 + 4 * mantissa / 1000000000000
                    //             + 2 * mantissa / 10000000000000 + 8 * mantissa / 100000000000000 + 4 * mantissa / 1000000000000000 + 2 * mantissa / 10000000000000000
                    //             + 1 * mantissa / 100000000000000000 + 2 * mantissa / 1000000000000000000 + 9 * mantissa / 10000000000000000000 + 3 * mantissa / 100000000000000000000;
                    assembly {
                        // Start with the base value
                        updatedMantissa := mantissa

                        // 6 * mantissa / 1000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 1000))

                        // 5 * mantissa / 10000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 10000))

                        // 1 * mantissa / 100000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 100000))

                        // 6 * mantissa / 1000000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 1000000))

                        // 9 * mantissa / 10000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 10000000))

                        // 2 * mantissa / 100000000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 100000000))

                        // 1 * mantissa / 1000000000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 1000000000))

                        // 9 * mantissa / 10000000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 10000000000))

                        // 8 * mantissa / 100000000000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 100000000000))

                        // 4 * mantissa / 1000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(4, mantissa), 1000000000000))

                        // 2 * mantissa / 10000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 10000000000000))

                        // 8 * mantissa / 100000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 100000000000000))

                        // 4 * mantissa / 1000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(4, mantissa), 1000000000000000))

                        // 2 * mantissa / 10000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 10000000000000000))

                        // 1 * mantissa / 100000000000000000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 100000000000000000))

                        // 2 * mantissa / 1000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 1000000000000000000))

                        // 9 * mantissa / 10000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 10000000000000000000))

                        // 3 * mantissa / 100000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 100000000000000000000))
                    }
                }
            } else {
                if (mantissa > (987274190490 * 10 ** 64)) {
                    q3 = 6;
                    // multiplier_q3 = 1.007825393982863782406809
                    // updatedMantissa = mantissa + 7 * mantissa / 1000 + 8 * mantissa / 10000
                    //             + 2 * mantissa / 100000 + 5 * mantissa / 1000000 + 3 * mantissa / 10000000 + 9 * mantissa / 100000000
                    //             + 3 * mantissa / 1000000000 + 9 * mantissa / 10000000000 + 8 * mantissa / 100000000000 + 2 * mantissa / 1000000000000
                    //             + 8 * mantissa / 10000000000000 + 6 * mantissa / 100000000000000 + 3 * mantissa / 1000000000000000 + 7 * mantissa / 10000000000000000
                    //             + 8 * mantissa / 100000000000000000 + 2 * mantissa / 1000000000000000000 + 4 * mantissa / 10000000000000000000
                    //             + 6 * mantissa / 1000000000000000000000 + 8 * mantissa / 10000000000000000000000 + 9 * mantissa / 1000000000000000000000000;
                    assembly {
                        // Start with the base value
                        updatedMantissa := mantissa

                        // 0 * mantissa / 10 (skip since it's zero)
                        // 0 * mantissa / 100 (skip since it's zero)

                        // 7 * mantissa / 1000
                        updatedMantissa := add(updatedMantissa, div(mul(7, mantissa), 1000))

                        // 8 * mantissa / 10000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 10000))

                        // 2 * mantissa / 100000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 100000))

                        // 5 * mantissa / 1000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 1000000))

                        // 3 * mantissa / 10000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 10000000))

                        // 9 * mantissa / 100000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 100000000))

                        // 3 * mantissa / 1000000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 1000000000))

                        // 9 * mantissa / 10000000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 10000000000))

                        // 8 * mantissa / 100000000000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 100000000000))

                        // 2 * mantissa / 1000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 1000000000000))

                        // 8 * mantissa / 10000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 10000000000000))

                        // 6 * mantissa / 100000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 100000000000000))

                        // 3 * mantissa / 1000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 1000000000000000))

                        // 7 * mantissa / 10000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(7, mantissa), 10000000000000000))

                        // 8 * mantissa / 100000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 100000000000000000))

                        // 2 * mantissa / 1000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 1000000000000000000))

                        // 4 * mantissa / 10000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(4, mantissa), 10000000000000000000))

                        // 0 * mantissa / 100000000000000000000 (skip since it's zero)

                        // 6 * mantissa / 1000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 1000000000000000000000))

                        // 8 * mantissa / 10000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 10000000000000000000000))

                        // 0 * mantissa / 100000000000000000000000 (skip since it's zero)

                        // 9 * mantissa / 1000000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 1000000000000000000000000))
                    }
                } else {
                    q3 = 7;
                    // multiplier_q3 = 1.0091355669950415053239378517
                    // updatedMantissa = mantissa + 9 * mantissa / 1000 + 1 * mantissa / 10000
                    //             + 3 * mantissa / 100000 + 5 * mantissa / 1000000 + 5 * mantissa / 10000000 + 6 * mantissa / 100000000
                    //             + 6 * mantissa / 1000000000 + 9 * mantissa / 10000000000 + 9 * mantissa / 100000000000 + 5 * mantissa / 1000000000000
                    //             + 4 * mantissa / 100000000000000 + 1 * mantissa / 1000000000000000 + 5 * mantissa / 10000000000000000
                    //             + 5 * mantissa / 1000000000000000000 + 3 * mantissa / 10000000000000000000 + 2 * mantissa / 100000000000000000000
                    //             + 3 * mantissa / 1000000000000000000000 + 9 * mantissa / 10000000000000000000000 + 3 * mantissa / 100000000000000000000000 + 7 * mantissa / 1000000000000000000000000
                    //             + 8 * mantissa / 10000000000000000000000000 + 5 * mantissa / 100000000000000000000000000 + 1 * mantissa / 1000000000000000000000000000 + 7 * mantissa / 10000000000000000000000000000;
                    assembly {
                        // Start with the base value
                        updatedMantissa := mantissa

                        // 0 * mantissa / 10 (skip since it's zero)
                        // 0 * mantissa / 100 (skip since it's zero)

                        // 9 * mantissa / 1000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 1000))

                        // 1 * mantissa / 10000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 10000))

                        // 3 * mantissa / 100000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 100000))

                        // 5 * mantissa / 1000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 1000000))

                        // 5 * mantissa / 10000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 10000000))

                        // 6 * mantissa / 100000000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 100000000))

                        // 6 * mantissa / 1000000000
                        updatedMantissa := add(updatedMantissa, div(mul(6, mantissa), 1000000000))

                        // 9 * mantissa / 10000000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 10000000000))

                        // 9 * mantissa / 100000000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 100000000000))

                        // 5 * mantissa / 1000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 1000000000000))

                        // 0 * mantissa / 10000000000000 (skip since it's zero)

                        // 4 * mantissa / 100000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(4, mantissa), 100000000000000))

                        // 1 * mantissa / 1000000000000000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 1000000000000000))

                        // 5 * mantissa / 10000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 10000000000000000))

                        // 0 * mantissa / 100000000000000000 (skip since it's zero)

                        // 5 * mantissa / 1000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 1000000000000000000))

                        // 3 * mantissa / 10000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 10000000000000000000))

                        // 2 * mantissa / 100000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(2, mantissa), 100000000000000000000))

                        // 3 * mantissa / 1000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 1000000000000000000000))

                        // 9 * mantissa / 10000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(9, mantissa), 10000000000000000000000))

                        // 3 * mantissa / 100000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(3, mantissa), 100000000000000000000000))

                        // 7 * mantissa / 1000000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(7, mantissa), 1000000000000000000000000))

                        // 8 * mantissa / 10000000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(8, mantissa), 10000000000000000000000000))

                        // 5 * mantissa / 100000000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(5, mantissa), 100000000000000000000000000))

                        // 1 * mantissa / 1000000000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mantissa, 1000000000000000000000000000))

                        // 7 * mantissa / 10000000000000000000000000000
                        updatedMantissa := add(updatedMantissa, div(mul(7, mantissa), 10000000000000000000000000000))
                    }
                }
            }
        }
    }
}
