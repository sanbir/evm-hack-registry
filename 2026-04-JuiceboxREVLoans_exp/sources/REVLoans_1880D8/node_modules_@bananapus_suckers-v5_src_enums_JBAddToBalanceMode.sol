// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Options for how a `JBSucker`'s `amountToAddToBalance` gets added to its project's balance.
/// @custom:element MANUAL The amount gets added to the project's balance manually by calling
/// `addOutstandingAmountToBalance`.
/// @custom:element ON_CLAIM The amount gets added to the project's balance automatically when `claim` is called.
enum JBAddToBalanceMode {
    MANUAL,
    ON_CLAIM
}
