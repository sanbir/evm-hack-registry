// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Custom errors for gas-efficient overflow handling
error TTSwapUINT256AddOverflow();
error TTSwapUINT256SubOverflow();
error TTSwapUINT256AddSubOverflow();
error TTSwapUINT256SubAddOverflow();
error TTSwapUINT256ToUint128Overflow();

using L_TTSwapUINT256Library for uint256;
/// @notice Converts two uint128 values into a T_BalanceUINT256
/// @param _amount0 The first 128-bit amount
/// @param _amount1 The second 128-bit amount
/// @return balanceDelta The resulting T_BalanceUINT256

function toTTSwapUINT256(
    uint128 _amount0,
    uint128 _amount1
) pure returns (uint256 balanceDelta) {
    assembly ("memory-safe") {
        balanceDelta := or(
            shl(128, _amount0),
            and(
                0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff,
                _amount1
            )
        )
    }
}

/// @notice Adds two T_BalanceUINT256 values
/// @param a The first T_BalanceUINT256
/// @param b The second T_BalanceUINT256
/// @return The sum of a and b as a T_BalanceUINT256
function add(uint256 a, uint256 b) pure returns (uint256) {
    uint256 res0;
    uint256 res1;
    uint256 a0;
    uint256 a1;
    uint256 b0;
    uint256 b1;
    assembly ("memory-safe") {
        a0 := shr(128, a)
        a1 := and(
            0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff,
            a
        )
        b0 := shr(128, b)
        b1 := and(
            0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff,
            b
        )
        res0 := add(a0, b0)
        res1 := add(a1, b1)
    }
    if (
        res0 < a0 ||
        res1 < a1 ||
        res0 >= type(uint128).max-1 ||
        res1 >= type(uint128).max-1
    ) revert TTSwapUINT256AddOverflow();
    return (res0 << 128) | res1;
}

/// @notice Subtracts two T_BalanceUINT256 values
/// @param a The first T_BalanceUINT256
/// @param b The second T_BalanceUINT256
/// @return The difference of a and b as a T_BalanceUINT256
function sub(uint256 a, uint256 b) pure returns (uint256) {
    uint256 res0;
    uint256 res1;
    uint256 a0;
    uint256 a1;
    uint256 b0;
    uint256 b1;
    unchecked {
        assembly ("memory-safe") {
            a0 := shr(128, a)
            a1 := and(
                0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff,
                a
            )
            b0 := shr(128, b)
            b1 := and(
                0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff,
                b
            )
            res0 := sub(a0, b0)
            res1 := sub(a1, b1)
        }
    }
    if (a0 < b0 || a1 < b1) revert TTSwapUINT256SubOverflow();
    return (res0 << 128) | res1;
}

/// @notice Adds the first components and subtracts the second components of two T_BalanceUINT256 values
/// @param a The first T_BalanceUINT256
/// @param b The second T_BalanceUINT256
/// @return The result of (a0 + b0, a1 - b1) as a T_BalanceUINT256
function addsub(uint256 a, uint256 b) pure returns (uint256) {
    uint256 res0;
    uint256 res1;
    uint256 a0;
    uint256 a1;
    uint256 b0;
    uint256 b1;
    unchecked {
        assembly ("memory-safe") {
            a0 := shr(128, a)
            a1 := and(
                0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff,
                a
            )
            b0 := shr(128, b)
            b1 := and(
                0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff,
                b
            )
            res0 := add(a0, b0)
            res1 := sub(a1, b1)
        }
    }
    if (res0 < a0 || a1 < b1 || res0 >= type(uint128).max)
        revert TTSwapUINT256AddSubOverflow();
    return (res0 << 128) | res1;
}

/// @notice Subtracts the first components and adds the second components of two T_BalanceUINT256 values
/// @param a The first T_BalanceUINT256
/// @param b The second T_BalanceUINT256
/// @return The result of (a0 - b0, a1 + b1) as a T_BalanceUINT256
function subadd(uint256 a, uint256 b) pure returns (uint256) {
    uint256 res0;
    uint256 res1;
    uint256 a0;
    uint256 a1;
    uint256 b0;
    uint256 b1;
    unchecked {
        assembly ("memory-safe") {
            a0 := shr(128, a)
            a1 := and(
                0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff,
                a
            )
            b0 := shr(128, b)
            b1 := and(
                0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff,
                b
            )
            res0 := sub(a0, b0)
            res1 := add(a1, b1)
        }
    }
    if (a0 < b0 || res1 < a1 || res1 >= type(uint128).max)
        revert TTSwapUINT256SubAddOverflow();
    return (res0 << 128) | res1;
}

/// @notice Safely converts a uint256 to a uint128
/// @param a The uint256 value to convert
/// @return b converted uint128 value, or 0 if overflow
function toUint128(uint256 a) pure returns (uint128 b) {
    b = uint128(a);
    if (a != uint256(b)) revert TTSwapUINT256ToUint128Overflow();
}

/// @notice Compares the prices of three T_BalanceUINT256 values using 512-bit arithmetic
/// @dev Avoids overflow: three uint128 multiplied can reach 2^384, exceeding uint256.
///      Uses mulmod trick to compute full 512-bit products for safe comparison.
/// @param a The first T_BalanceUINT256
/// @param b The second T_BalanceUINT256
/// @param c The third T_BalanceUINT256
/// @return result True if a0*b1*c1 > a1*b0*c0, false otherwise
function lowerprice(
    uint256 a,
    uint256 b,
    uint256 c
) pure returns (bool result) {
    assembly {
        let mask := 0xffffffffffffffffffffffffffffffff
        let a0 := shr(128, a)
        let a1 := and(a, mask)
        let b0 := shr(128, b)
        let b1 := and(b, mask)
        let c0 := shr(128, c)
        let c1 := and(c, mask)

        // L = a0 * b1, R = a1 * b0 (each fits in uint256: uint128 * uint128 <= 2^256 - 2^129 + 1)
        let L := mul(a0, b1)
        let R := mul(a1, b0)

        // Full 512-bit multiplication: L * c1 = lHi:lLo
        let lLo := mul(L, c1)
        let mm := mulmod(L, c1, not(0))
        let lHi := sub(sub(mm, lLo), lt(mm, lLo))

        // Full 512-bit multiplication: R * c0 = rHi:rLo
        let rLo := mul(R, c0)
        mm := mulmod(R, c0, not(0))
        let rHi := sub(sub(mm, rLo), lt(mm, rLo))

        // Compare 512-bit: lHi:lLo > rHi:rLo
        result := or(gt(lHi, rHi), and(eq(lHi, rHi), gt(lLo, rLo)))
    }
}

/// @notice Performs a multiplication followed by a division (full precision)
/// @dev Optimized to prevent intermediate overflow during multiplication
/// @param config The multiplicand
/// @param amount The multiplier
/// @param divisor The divisor
/// @return a The result as a uint128
function mulDiv(
    uint256 config,
    uint256 amount,
    uint256 divisor
) pure returns (uint128 a) {
    uint256 result;
    if (divisor == 0) revert();
    assembly {
        config := mul(config, amount)
        result := div(config, divisor)
    }
    return toUint128(result);
}

/// @title L_TTSwapUINT256Library
/// @notice A library for operations on T_BalanceUINT256
library L_TTSwapUINT256Library {
    /// @notice Extracts the first 128-bit amount from a T_BalanceUINT256
    /// @param balanceDelta The T_BalanceUINT256 to extract from
    /// @return _amount0 The extracted first 128-bit amount
    function amount0(
        uint256 balanceDelta
    ) internal pure returns (uint128 _amount0) {
        assembly {
            _amount0 := shr(128, balanceDelta)
        }
    }

    /// @notice Extracts the second 128-bit amount from a T_BalanceUINT256
    /// @param balanceDelta The T_BalanceUINT256 to extract from
    /// @return _amount1 The extracted second 128-bit amount
    function amount1(
        uint256 balanceDelta
    ) internal pure returns (uint128 _amount1) {
        assembly {
            _amount1 := balanceDelta
        }
    }

    /// @notice Extracts the first and second 128-bit amounts from a T_BalanceUINT256
    /// @param balanceDelta The T_BalanceUINT256 to extract from
    /// @return _amount0 The extracted first 128-bit amount
    /// @return _amount1 The extracted second 128-bit amount
    function amount01(
        uint256 balanceDelta
    ) internal pure returns (uint128 _amount0, uint128 _amount1) {
        assembly {
            _amount0 := shr(128, balanceDelta)
            _amount1 := balanceDelta
        }
    }

    /// @notice Calculates amount0 based on a given amount1 and the ratio in balanceDelta
    /// @param balanceDelta The T_BalanceUINT256 containing the ratio
    /// @param amount1delta The amount1 to base the calculation on
    /// @return _amount0 The calculated amount0
    function getamount0fromamount1(
        uint256 balanceDelta,
        uint128 amount1delta
    ) internal pure returns (uint128 _amount0) {
        return
            mulDiv(
                balanceDelta.amount0(),
                amount1delta,
                balanceDelta.amount1()
            );
    }

    /// @notice Calculates amount1 based on a given amount0 and the ratio in balanceDelta
    /// @param balanceDelta The T_BalanceUINT256 containing the ratio
    /// @param amount0delta The amount0 to base the calculation on
    /// @return _amount1 The calculated amount1
    function getamount1fromamount0(
        uint256 balanceDelta,
        uint128 amount0delta
    ) internal pure returns (uint128 _amount1) {
        return
            mulDiv(
                balanceDelta.amount1(),
                amount0delta,
                balanceDelta.amount0()
            );
    }
}
