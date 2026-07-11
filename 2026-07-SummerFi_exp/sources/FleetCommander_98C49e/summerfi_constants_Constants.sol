// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

library Constants {
    // WAD: Common unit, stands for "18 decimals"
    uint256 public constant WAD = 1e18;

    // RAY: Higher precision unit, "27 decimals"
    uint256 public constant RAY = 1e27;

    // Conversion factor from WAD to RAY
    uint256 public constant WAD_TO_RAY = 1e9;

    // Number of seconds in a day
    uint256 public constant SECONDS_PER_DAY = 1 days;

    // Number of seconds in a year (assuming 365 days)
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // Maximum value for uint256
    uint256 public constant MAX_UINT256 = type(uint256).max;

    // AAVE V3 POOL CONFIG DATA MASK

    uint256 internal constant ACTIVE_MASK =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFFFFFFFF;
    uint256 internal constant FROZEN_MASK =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFDFFFFFFFFFFFFFF;
    uint256 internal constant PAUSED_MASK =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFFFFFFFFF;
}
