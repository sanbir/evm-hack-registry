// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

library MathUtils {
    /// Constants for masking in calculating MSB.
    uint256 public constant SHIFT128 = ((1 << 128) - 1) << 128;
    uint256 public constant SHIFT64 = ((1 << 64) - 1) << 64;
    uint256 public constant SHIFT32 = ((1 << 32) - 1) << 32;
    uint256 public constant SHIFT16 = ((1 << 16) - 1) << 16;
    uint256 public constant SHIFT8 = ((1 << 8) - 1) << 8;
    uint256 public constant SHIFT4 = ((1 << 4) - 1) << 4;
    uint256 public constant SHIFT2 = ((1 << 2) - 1) << 2;
    uint256 public constant SHIFT1 = 0x2;

    function abs(int256 self) internal pure returns (int256) {
        return self >= 0 ? self : -self;
    }

    /// @notice Calculates the square root of x using the Babylonian method.
    ///
    /// @dev See https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method.
    /// Copied from PRBMath: https://github.com/PaulRBerg/prb-math/blob/83b3a0dcd4aaca779d0632118772f00611340e79/src/Common.sol
    ///
    /// Notes:
    /// - If x is not a perfect square, the result is rounded down.
    /// - Credits to OpenZeppelin for the explanations in comments below.
    ///
    /// @param x The uint256 number for which to calculate the square root.
    /// @return result The result as a uint256.
    /// @custom:smtchecker abstract-function-nondet
    function sqrt(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) {
            return 0;
        }

        // For our first guess, we calculate the biggest power of 2 which is smaller than the square root of x.
        //
        // We know that the "msb" (most significant bit) of x is a power of 2 such that we have:
        //
        // $$
        // msb(x) <= x <= 2*msb(x)$
        // $$
        //
        // We write $msb(x)$ as $2^k$, and we get:
        //
        // $$
        // k = log_2(x)
        // $$
        //
        // Thus, we can write the initial inequality as:
        //
        // $$
        // 2^{log_2(x)} <= x <= 2*2^{log_2(x)+1}
        // sqrt(2^k) <= sqrt(x) < sqrt(2^{k+1})
        // 2^{k/2} <= sqrt(x) < 2^{(k+1)/2} <= 2^{(k/2)+1}
        // $$
        //
        // Consequently, $2^{log_2(x) /2} is a good first approximation of sqrt(x) with at least one correct bit.
        uint256 xAux = uint256(x);
        result = 1;
        if (xAux >= 2 ** 128) {
            xAux >>= 128;
            result <<= 64;
        }
        if (xAux >= 2 ** 64) {
            xAux >>= 64;
            result <<= 32;
        }
        if (xAux >= 2 ** 32) {
            xAux >>= 32;
            result <<= 16;
        }
        if (xAux >= 2 ** 16) {
            xAux >>= 16;
            result <<= 8;
        }
        if (xAux >= 2 ** 8) {
            xAux >>= 8;
            result <<= 4;
        }
        if (xAux >= 2 ** 4) {
            xAux >>= 4;
            result <<= 2;
        }
        if (xAux >= 2 ** 2) {
            result <<= 1;
        }

        // At this point, `result` is an estimation with at least one bit of precision. We know the true value has at
        // most 128 bits, since it is the square root of a uint256. Newton's method converges quadratically (precision
        // doubles at every iteration). We thus need at most 7 iteration to turn our partial result with one bit of
        // precision into the expected uint128 result.
        unchecked {
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;

            // If x is not a perfect square, round the result toward zero.
            uint256 roundedResult = x / result;
            if (result >= roundedResult) {
                result = roundedResult;
            }
        }
    }

    /// Get an X256 number representing the ratio of a/b where a < b.
    /// This rounds down. Generally, you'll want to multiply this ratio with another value through X256.mul256.
    /// @dev b must be greater than 1.
    /// @dev BE AWARE OF WHEN THIS IS INACCURATE. THERE ARE VERY RARE INSTANCES WHERE THIS IS APPROPRIATE.
    /// The inaccuracy is significant.
    /// @custom:gas 104
    function percentX256(uint256 a, uint256 b) internal pure returns (uint256 ratioX256) {
        if (a == b) return uint256(int256(-1));
        /// We actually compute 2^256 / b first extremely cheaply. ~20 gas
        require(b > 1, "0");
        assembly {
            ratioX256 := add(div(sub(0, b), b), 1)
            ratioX256 := mul(a, ratioX256)
        }
        // The multiplication always fits since a < b
    }

    /// Calculate the most significant bit's place, 0th indexed.
    /// @dev Also returns 0 if the input is 0.
    function msb(uint256 x) internal pure returns (uint8 place) {
        if (x == 0) return 0;

        if ((x & SHIFT128) != 0) {
            place += 128;
            x >>= 128;
        }

        if ((x & SHIFT64) != 0) {
            place += 64;
            x >>= 64;
        }

        if ((x & SHIFT32) != 0) {
            place += 32;
            x >>= 32;
        }

        if ((x & SHIFT16) != 0) {
            place += 16;
            x >>= 16;
        }

        if ((x & SHIFT8) != 0) {
            place += 8;
            x >>= 8;
        }

        if ((x & SHIFT4) != 0) {
            place += 4;
            x >>= 4;
        }

        if ((x & SHIFT2) != 0) {
            place += 2;
            x >>= 2;
        }

        if ((x & SHIFT1) != 0) {
            place += 1;
            x >>= 1;
        }
    }
}
