// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Options for the deprecation state of a `JBSucker`.
/// @custom:member ENABLED The `JBSucker` is not deprecated.
/// @custom:member DEPRECATION_PENDING The `JBSucker` has a deprecation set, but it is still fully functional.
/// @custom:member SENDING_DISABLED The `JBSucker` is deprecated and sending to the pair sucker is disabled.
/// @custom:member DEPRECATED The `JBSucker` is deprecated, but it continues to let users claim their funds.
enum JBSuckerState {
    ENABLED,
    DEPRECATION_PENDING,
    SENDING_DISABLED,
    DEPRECATED
}
