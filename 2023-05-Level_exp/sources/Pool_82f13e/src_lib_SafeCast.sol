// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.8.0) (utils/ma/SafeCast.solth)
// This file was procedurally generated from scripts/generate/templates/SafeCast.js.

pragma solidity ^0.8.0;

/**
 * @dev Extract from OpenZeppelin SafeCast to shorten revert message
 */
library SafeCast {
    function toUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "SafeCast: value < 0");
        return uint256(value);
    }

    function toInt256(uint256 value) internal pure returns (int256) {
        // Note: Unsafe cast below is okay because `type(int256).max` is guaranteed to be positive
        require(value <= uint256(type(int256).max), "SafeCast: value > int256.max");
        return int256(value);
    }
}
