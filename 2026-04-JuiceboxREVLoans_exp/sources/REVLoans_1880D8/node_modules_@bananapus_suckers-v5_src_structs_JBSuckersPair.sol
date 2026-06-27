// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @custom:member local The local address.
/// @custom:member remote The remote address.
/// @custom:member remoteChainId The chain ID of the remote address.
struct JBSuckersPair {
    address local;
    address remote;
    uint256 remoteChainId;
}
