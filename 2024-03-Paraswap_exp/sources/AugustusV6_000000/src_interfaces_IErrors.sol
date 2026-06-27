// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

/// @title IErrors
/// @notice Common interface for errors
interface IErrors {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the returned amount is less than the minimum amount
    error InsufficientReturnAmount();

    /// @notice Emitted when the specified toAmount is less than the minimum amount (2)
    error InvalidToAmount();
}
