// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A leaf in the inbox or outbox tree of a `JBSucker`. Used to `claim` tokens from the inbox tree.
/// @custom:member index The index of the leaf.
/// @custom:member beneficiary The beneficiary of the leaf.
/// @custom:member projectTokenCount The number of project tokens to claim.
/// @custom:member terminalTokenAmount The amount of terminal tokens to claim.
struct JBLeaf {
    uint256 index;
    address beneficiary;
    uint256 projectTokenCount;
    uint256 terminalTokenAmount;
}
