// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

using TickRangeImpl for TickRange global;

/// Defines the tick range of an AMM position.
struct TickRange {
    /// Lower tick of the range.
    int24 lower;
    /// Upper tick of the range.
    int24 upper;
}

/// Implementation library for TickRange.
library TickRangeImpl {
    /// @notice Checks whether the given range is encoded to represent the island.
    /// @param range The range to check.
    /// @return isIsland True if the range is for an island.
    function isIsland(TickRange memory range) internal pure returns (bool) {
        return range.lower == 0 && range.upper == 0;
    }
}
