// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The root of an inbox tree for a given token in a `JBSucker`.
/// @dev Inbox trees are used to receive from the remote chain to the local chain. Tokens can be `claim`ed from the
/// inbox tree.
/// @custom:member nonce Tracks the nonce of the tree. The nonce cannot decrease.
/// @custom:member root The root of the tree.
struct JBInboxTreeRoot {
    uint64 nonce;
    bytes32 root;
}
