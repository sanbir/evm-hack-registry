// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

/// @notice Thrown if the supplied address is a zero address where it is not allowed
error ZeroAddressNotAllowed();

/// @notice Thrown if the supplied value is 0 where it is not allowed
error ZeroValueNotAllowed();

/// @notice Checks if the provided address is nonzero, reverts otherwise
/// @param address_ Address to check
/// @custom:error ZeroAddressNotAllowed is thrown if the provided address is a zero address
function ensureNonzeroAddress(address address_) pure {
    if (address_ == address(0)) {
        revert ZeroAddressNotAllowed();
    }
}

/// @notice Checks if the provided value is nonzero, reverts otherwise
/// @param value_ Value to check
/// @custom:error ZeroValueNotAllowed is thrown if the provided value is 0
function ensureNonzeroValue(uint256 value_) pure {
    if (value_ == 0) {
        revert ZeroValueNotAllowed();
    }
}
