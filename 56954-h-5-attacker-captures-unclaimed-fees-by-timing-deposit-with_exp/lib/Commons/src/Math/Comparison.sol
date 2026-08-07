// SPDX-License-Identifier: MIT
// Copyright 2024 Itos Inc.
pragma solidity ^0.8.13;

/// @notice Math comparison lib for int24 numbers
library Int24ComparisonLib {
    /// Returns the smaller of two numbers
    function min(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }

    /// Returns the larger of two numbers
    function max(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a : b;
    }
}

/// @notice Math comparison lib for int256 numbers
library Int256ComparisonLib {
    /// Returns the smaller of two numbers
    function min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    /// Returns the larger of two numbers
    function max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }
}

/// @notice Math comparison lib for uint24 numbers
library Uint24ComparisonLib {
    /// Returns the smaller of two numbers
    function min(uint24 a, uint24 b) internal pure returns (uint24) {
        return a < b ? a : b;
    }

    /// Returns the larger of two numbers
    function max(uint24 a, uint24 b) internal pure returns (uint24) {
        return a > b ? a : b;
    }
}

/// @notice Math comparison lib for uint256 numbers
library Uint256ComparisonLib {
    /// Returns the smaller of two numbers
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// Returns the larger of two numbers
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
