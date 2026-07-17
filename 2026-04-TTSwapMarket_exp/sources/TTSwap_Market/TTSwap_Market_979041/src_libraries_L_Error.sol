// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;


/// @notice Defines the standard error type used throughout the TTSwap protocol.
/// @dev Errors are identified by a unique sequence code `seq` to save bytecode size compared to string revert messages.
error TTSwapError(uint256 seq);
