// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title SqrtMath
/// @notice Integer square root using the Babylonian method (same as Uniswap V2).
library SqrtMath {
    /**
     * @notice Computes `floor(sqrt(y))` for any `uint256`.
     * @param y Input value.
     * @return z The integer square root of `y`.
     */
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
