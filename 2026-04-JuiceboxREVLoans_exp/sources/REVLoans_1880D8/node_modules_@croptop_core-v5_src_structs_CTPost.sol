// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A post to be published.
/// @custom:member encodedIPFSUri The encoded IPFS URI of the post that is being published.
/// @custom:member totalSupply The number of NFTs that should be made available, including the 1 that will be minted
/// alongside this transaction.
/// @custom:member price The price being paid for buying the post that is being published.
/// @custom:member category The category that the post should be published in.
struct CTPost {
    bytes32 encodedIPFSUri;
    uint32 totalSupply;
    uint104 price;
    uint24 category;
}
