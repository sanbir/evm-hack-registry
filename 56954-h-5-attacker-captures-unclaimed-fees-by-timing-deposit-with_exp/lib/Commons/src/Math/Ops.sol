// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { FullMath } from "./FullMath.sol";
import { MathUtils } from "./Utils.sol";

library X32 {
    /// The two numbers are too large to fit the result into one uint256.
    error OversizedX32(uint256 a, uint256 b);

    uint256 public constant SHIFT = 1 << 32;

    // Multiply two 256 bit numbers to a 512 number, but one of the 256's is X32.
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 bot, uint256 top) {
        (uint256 rawB, uint256 rawT) = FullMath.mul512(a, b);
        bot = (rawB >> 32) + (rawT << 224);
        top = rawT >> 32;
    }

    /// Multiply two numbers and reduce by 2^32. The result must fit in a 256 bit or it'll error.
    function mul256(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            res := add(add(shr(32, bot), shl(224, top)), and(roundUp, gt(mod(bot, modmax), 0)))
        }
    }
}

library X64 {
    /// The two numbers are too large to fit the result into one uint256.
    error OversizedX64(uint256 a, uint256 b);

    uint256 public constant SHIFT = 1 << 64;

    /// Multiply two 256 numbers with X64 precision with your desired rounding.
    /// @dev The result must fit in 256 bits or will give an incorrect answer.
    function mul256(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            res := add(add(shr(64, bot), shl(192, top)), and(roundUp, gt(mod(bot, modmax), 0)))
        }
    }

    // Multiply two 256 bit numbers to a 512 number, but one of the 256's is X32.
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 bot, uint256 top) {
        (uint256 rawB, uint256 rawT) = FullMath.mul512(a, b);
        bot = (rawB >> 64) + (rawT << 192);
        top = rawT >> 64;
    }

    /// Multiply and round down after reducing by 2^64. Error if the result is too large.
    function safeMul512(uint256 a, uint256 b) internal pure returns (uint256 res) {
        uint256 top;
        (res, top) = mul512(a, b);
        if (top > 0) revert OversizedX64(a, b);
    }
}

/**
 * @notice Utility for Q64.96 operations
 *
 */
library Q64X96 {
    uint256 constant PRECISION = 96;

    uint256 constant SHIFT = 1 << 96;

    error Q64X96Overflow(uint160 a, uint256 b);

    /// Multiply an X96 precision number by an arbitrary uint256 number.
    /// Returns with the same precision as b.
    /// The result takes up 256 bits. Will error on overflow.
    function mul(uint160 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath.mul512(a, b);
        if ((top >> 96) > 0) {
            revert Q64X96Overflow(a, b);
        }
        assembly {
            res := add(shr(96, bot), shl(160, top))
        }
        if (roundUp && (bot % SHIFT > 0)) {
            res += 1;
        }
    }

    /// Same as the regular mul but without checking for overflow
    function unsafeMul(uint160 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath.mul512(a, b);
        assembly {
            res := add(shr(96, bot), shl(160, top))
        }
        if (roundUp) {
            uint256 modby = SHIFT;
            assembly {
                res := add(res, gt(mod(bot, modby), 0))
            }
        }
    }

    /// Divide a uint160 by a Q64X96 number.
    /// Returns with the same precision as num.
    /// @dev uint160 is chosen because once the 96 bits of precision are cancelled out,
    /// the result is at most 256 bits.
    function div(uint160 num, uint160 denom, bool roundUp) internal pure returns (uint256 res) {
        uint256 fullNum = uint256(num) << PRECISION;
        res = fullNum / denom;
        if (roundUp) {
            assembly {
                res := add(res, gt(fullNum, mul(res, denom)))
            }
        }
    }
}

library X96 {
    uint256 constant PRECISION = 96;
    uint256 constant SHIFT = 1 << 96;

    /// Multiply two 256 numbers with X96 precision with your desired rounding.
    /// @dev The result must fit in 256 bits or will silently give an incorrect answer.
    function mul256(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            res := add(add(shr(96, bot), shl(160, top)), and(roundUp, gt(mod(bot, modmax), 0)))
        }
    }
}

library X128 {
    /// The two numbers are too large to fit the result into one uint256.
    error Oversized(uint256 a, uint256 b);

    uint256 constant PRECISION = 128;

    uint256 constant SHIFT = 1 << 128;

    /// Multiply a 256 bit number by a 128 bit number. Either of which is X128.
    /// @dev This rounds results down.
    function mul256(uint128 a, uint256 b) internal pure returns (uint256) {
        (uint256 bot, uint256 top) = FullMath.mul512(a, b);
        unchecked {
            return (bot >> 128) + (top << 128);
        }
    }

    /// Multiply a 256 bit number by a 128 bit number. Either of which is X128.
    /// @dev This rounds results up.
    function mul256RoundUp(uint128 a, uint256 b) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            res := add(add(shr(128, bot), shl(128, top)), gt(mod(bot, modmax), 0))
        }
    }

    /// Multiply two 256 numbers with X128 precision with your desired rounding.
    /// @dev The result must fit in 256 bits or will silently give an incorrect answer.
    function mul256(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            res := add(add(shr(128, bot), shl(128, top)), and(roundUp, gt(mod(bot, modmax), 0)))
        }
    }

    /// Multiply a 256 bit number by a 256 bit number, either of which is X128, to get 384 bits.
    /// @dev This rounds results down.
    /// @return bot The bottom 256 bits of the result.
    /// @return top The top 128 bits of the result.
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 bot, uint256 top) {
        (uint256 _bot, uint256 _top) = FullMath.mul512(a, b);
        unchecked {
            bot = (_bot >> 128) + (_top << 128);
            top = _top >> 128;
        }
    }

    /// Multiply a 256 bit number by a 256 bit number, either of which is X128, to get 384 bits.
    /// @dev This rounds results up.
    /// @return bot The bottom 256 bits of the result.
    /// @return top The top 128 bits of the result.
    function mul512RoundUp(uint256 a, uint256 b) internal pure returns (uint256 bot, uint256 top) {
        (uint256 _bot, uint256 _top) = FullMath.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            bot := add(add(shr(128, _bot), shl(128, top)), gt(mod(_bot, modmax), 0))
            top := shr(128, _top)
        }
    }

    /// mul512 but error if oversized.
    function safeMul512(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = roundUp ? mul512RoundUp(a, b) : mul512(a, b);
        if (top > 0) revert Oversized(a, b);
        return bot;
    }

    /// Divide two numbers to get an X128 result.
    /// @dev Will error on overflow.
    /// Unlike full math, this gives an approximate answer that may be off by 2/128th of the result.
    /// In return, the common case costs ~40 gas and at most this costs ~300 gas.
    function divTo(uint256 a, uint256 b) internal pure returns (uint256 resX128) {
        bool rev;
        (resX128, rev) = tryDivTo(a, b);
        if (rev) revert Oversized(a, b);
    }

    /// Attempt to divide a by b to get an X128 result. If the result is too large 0 and true is returned.
    /// @dev TODO: untested
    /// @dev This rounds down.
    function tryDivTo(uint256 a, uint256 b) internal pure returns (uint256 resX128, bool overFlow) {
        uint256 whole = a / b; // Whole result
        // Can't fit in Q128X128
        if (whole >= SHIFT) return (0, true);
        uint256 residual;
        unchecked {
            // Q128 part
            resX128 = whole << 128;
            // X128 part
            residual = a % b;
        }
        // If the residual is small we can go ahead with regular division.
        if (residual < SHIFT) {
            // The common case
            unchecked {
                resX128 += (residual << 128) / b;
            }
            return (resX128, false);
        }
        // If the residual is too large, we try to shift up by as much as we can while still fitting into 256 bit arithmetic.
        uint8 rMSB = MathUtils.msb(residual); // Could save 9 gas by making a tailored one for just the relevant 128 bits.
        /// Residual greather or equal to SHIFT means rMSB >= 128.
        uint8 shiftUp;
        uint8 shiftDown;
        unchecked {
            shiftUp = 255 - rMSB;
            shiftDown = 128 - shiftUp;
        }
        // These two shifts combine to add the X128 bits.
        // TODO: Handle rounding up
        uint256 denom = b >> shiftDown;
        if (b % (1 << shiftDown) > 0) {
            denom += 1;
        }
        resX128 += (residual << shiftUp) / denom;
    }
}

library X256 {
    /// Multiply a 256 bit number by a 256 bit number and div by 2^256.
    /// @custom:gas 212
    function mul256(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256) {
        (uint256 bot, uint256 top) = FullMath.mul512(a, b);
        assembly {
            top := add(top, and(roundUp, gt(bot, 0)))
        }
        return top;
    }
}


/// Convenience library for interacting with Uint128s by other types.
library U128Ops {
    function add(uint128 self, int128 other) public pure returns (uint128) {
        if (other >= 0) {
            return self + uint128(other);
        } else {
            return self - uint128(-other);
        }
    }

    function sub(uint128 self, int128 other) public pure returns (uint128) {
        if (other >= 0) {
            return self - uint128(other);
        } else {
            return self + uint128(-other);
        }
    }
}

library U256Ops {
    function add(uint256 self, int256 other) public pure returns (uint256) {
        if (other >= 0) {
            return self + uint256(other);
        } else {
            return self - uint256(-other);
        }
    }

    function sub(uint256 self, uint256 other) public pure returns (int256) {
        if (other >= self) {
            uint256 temp = other - self;
            // Yes technically the max should be -type(int256).max but that's annoying to
            // get right and cheap for basically no benefit.
            require(temp <= uint256(type(int256).max));
            return -int256(temp);
        } else {
            uint256 temp = self - other;
            require(temp <= uint256(type(int256).max));
            return int256(temp);
        }
    }
}
