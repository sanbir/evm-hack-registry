// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

/// Library for safe casting
library SafeCast {
    /// Casting too large an int to a signed int with the given maximum value.
    error UnsafeICast(uint256 val, int256 max);
    /// Casting too large an int to an unsigned int with the given maximum value.
    error UnsafeUCast(uint256 val, uint256 max);
    /// Casting a negative number to an unsigned int.
    error NegativeUCast(int256 val);

    function toUint256(int256 i) internal pure returns (uint256) {
        if (i < 0) {
            revert NegativeUCast(i);
        }
        return uint256(i);
    }

    function toInt256(uint256 u) internal pure returns (int256) {
        if (u > uint256(type(int256).max)) {
            revert UnsafeICast(u, type(int256).max);
        }
        return int256(u);
    }

    function toInt128(uint256 u) internal pure returns (int128) {
        if (u > uint256(uint128(type(int128).max))) {
            revert UnsafeICast(u, type(int128).max);
        }
        return int128(uint128(u));
    }

    function toUint128(uint256 u) internal pure returns (uint128) {
        if (u > type(uint128).max) {
            revert UnsafeUCast(u, type(uint128).max);
        }
        return uint128(u);
    }

    function toUint128(int256 i) internal pure returns (uint128) {
        return toUint128(toUint256(i));
    }

    function toUint160(uint256 u) internal pure returns (uint160) {
        if (u > type(uint160).max) {
            revert UnsafeUCast(u, type(uint160).max);
        }
        return uint160(u);
    }

    function toUint96(uint256 u) internal pure returns (uint96) {
        if (u > type(uint96).max) {
            revert UnsafeUCast(u, type(uint96).max);
        }
        return uint96(u);
    }

    function toUint96(int256 i) internal pure returns (uint96) {
        return toUint96(toUint256(i));
    }

    function toInt24(uint24 u) internal pure returns (int24) {
        if (u > uint24(type(int24).max)) {
            revert UnsafeICast(u, type(int24).max);
        }
        return int24(u);
    }
}
