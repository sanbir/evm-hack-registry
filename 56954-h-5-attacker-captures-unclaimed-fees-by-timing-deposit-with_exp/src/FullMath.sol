// SPDX-License-Identifier: MIT
pragma solidity >=0.4.0;

/// @title Contains 512-bit math functions
/// @author Uniswap Team
/// @notice Facilitates multiplication and division that can have overflow of an intermediate value without any loss of precision
/// @dev Handles "phantom overflow" i.e., allows multiplication and division where an intermediate value overflows 256 bits
library FullMath {
    uint256 constant X128 = 1 << 128;

    /// @notice Calculates floor(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    /// @dev Credit to Remco Bloemen under MIT license https://xn--2-umb.com/21/muldiv
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        // 512-bit multiply [prod1 prod0] = a * b
        // Compute the product mod 2**256 and mod 2**256 - 1
        // then use the Chinese Remainder Theorem to reconstruct
        // the 512 bit result. The result is stored in two 256
        // variables such that product = prod1 * 2**256 + prod0
        uint256 prod0; // Least significant 256 bits of the product
        uint256 prod1; // Most significant 256 bits of the product
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // Handle non-overflow cases, 256 by 256 division
        if (prod1 == 0) {
            require(denominator > 0);
            assembly {
                result := div(prod0, denominator)
            }
            return result;
        }

        // Make sure the result is less than 2**256.
        // Also prevents denominator == 0
        require(denominator > prod1);

        ///////////////////////////////////////////////
        // 512 by 256 division.
        ///////////////////////////////////////////////

        // Make division exact by subtracting the remainder from [prod1 prod0]
        // Compute remainder using mulmod
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
        }
        // Subtract 256 bit number from 512 bit number
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        // Factor powers of two out of denominator
        // Compute largest power of two divisor of denominator.
        // Always >= 1.
        uint256 twos = uint256(-int256(denominator)) & denominator;
        // Divide denominator by power of two
        assembly {
            denominator := div(denominator, twos)
        }

        // Divide [prod1 prod0] by the factors of two
        assembly {
            prod0 := div(prod0, twos)
        }
        // Shift in bits from prod1 into prod0. For this we need
        // to flip `twos` such that it is 2**256 / twos.
        // If twos is zero, then it becomes one
        assembly {
            twos := add(div(sub(0, twos), twos), 1)
        }
        unchecked {
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256
            // Now that denominator is an odd number, it has an inverse
            // modulo 2**256 such that denominator * inv = 1 mod 2**256.
            // Compute the inverse by starting with a seed that is correct
            // correct for four bits. That is, denominator * inv = 1 mod 2**4

            uint256 inv = (3 * denominator) ^ 2;
            // Now use Newton-Raphson iteration to improve the precision.
            // Thanks to Hensel's lifting lemma, this also works in modular
            // arithmetic, doubling the correct bits in each step.
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            // Because the division is now exact we can divide by multiplying
            // with the modular inverse of denominator. This will give us the
            // correct result modulo 2**256. Since the precoditions guarantee
            // that the outcome is less than 2**256, this is the final result.
            // We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inv;
        }
        return result;
    }

    /// @notice Calculates ceil(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    function mulDivRoundingUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            require(result < type(uint256).max);
            result++;
        }
    }

    /// A slightly optimized version of mulDiv for when we want to divide a by b (where b > a) and get an X256 result.
    /// @custom:gas 548
    function mulDivX256(
        uint256 num,
        uint256 denominator,
        bool roundUp
    ) internal pure returns (uint256 result) {
        require(denominator > num, "0");

        ///////////////////////////////////////////////
        // 512 by 256 division.
        ///////////////////////////////////////////////

        // Make division exact by subtracting out the remainder.
        uint256 remainder;
        assembly {
            remainder := mulmod(num, X128, denominator)
            remainder := mulmod(remainder, X128, denominator)
        }
        roundUp = roundUp && (remainder > 0);
        // Subtract out the remainder. Now remainder holds the fractional portion.
        assembly {
            num := sub(num, gt(remainder, 0))
            remainder := sub(0, remainder)
        }
        // Factor powers of two out of denominator
        // Compute largest power of two divisor of denominator.
        // Always >= 1.
        uint256 twos = uint256(-int256(denominator)) & denominator;
        assembly {
            remainder := div(remainder, twos)
        }
        assembly {
            denominator := div(denominator, twos)
        }

        // Shift in bits from the whole into the fraction. For this we need
        // to flip `twos` such that it is 2**256 / twos.
        // If twos is zero, then it becomes one
        assembly {
            twos := add(div(sub(0, twos), twos), 1)
        }
        unchecked {
            remainder |= num * twos;

            // Follow Remco Bloeman's inversion process.
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256
            // We know the result is entirely fractional.
            result = remainder * inv;
        }
        if (roundUp) result += 1;
        return result;
    }

    /// Calculates a 512 bit product of two 256 bit numbers.
    /// @return r0 The lower 256 bits of the result.
    /// @return r1 The higher 256 bits of the result.
    function mul512(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256 r0, uint256 r1) {
        assembly {
            let mm := mulmod(a, b, not(0))
            r0 := mul(a, b)
            r1 := sub(sub(mm, r0), lt(mm, r0))
        }
    }

    /// Short circuit mulDiv if the multiplicands don't overflow.
    /// Use this when you expect the input values to be small in most cases.
    /// @dev This charges an extra ~20 gas on top of the regular mulDiv if used, but otherwise costs 30 gas
    function shortMulDiv(
        uint256 m0,
        uint256 m1,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        uint256 num;
        unchecked {
            num = m0 * m1;
        }
        if (num == 0) return 0;

        unchecked {
            if (num / m0 == m1) {
                return num / denominator;
            } else {
                return mulDiv(m0, m1, denominator);
            }
        }
    }

    /// Multiply two numbers and divide out by 128 bits to get a 256 bit number.
    /// @dev Be careful when using this. If there is overflow you won't be warned.
    function mulX128(
        uint256 a,
        uint256 b,
        bool roundUp
    ) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath.mul512(a, b);
        uint256 modmax = 1 << 128;
        assembly {
            res := add(
                add(shr(128, bot), shl(128, top)),
                and(roundUp, gt(mod(bot, modmax), 0))
            )
        }
    }

    /// Multiply two 256 bit number and shift the result by 256
    function mulX256(
        uint256 a,
        uint256 b,
        bool roundUp
    ) internal pure returns (uint256) {
        (uint256 bot, uint256 top) = FullMath.mul512(a, b);
        if (roundUp && bot > 0) top += 1;
        return top;
    }
}
