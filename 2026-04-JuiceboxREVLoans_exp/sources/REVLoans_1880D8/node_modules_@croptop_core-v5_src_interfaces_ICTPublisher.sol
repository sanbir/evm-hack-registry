// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJB721TiersHook} from "@bananapus/721-hook-v5/src/interfaces/IJB721TiersHook.sol";
import {JB721Tier} from "@bananapus/721-hook-v5/src/structs/JB721Tier.sol";
import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";

import {CTAllowedPost} from "../structs/CTAllowedPost.sol";
import {CTPost} from "../structs/CTPost.sol";

interface ICTPublisher {
    event ConfigurePostingCriteria(address indexed hook, CTAllowedPost allowedPost, address caller);
    event Mint(
        uint256 indexed projectId,
        IJB721TiersHook indexed hook,
        address indexed nftBeneficiary,
        address feeBeneficiary,
        CTPost[] posts,
        uint256 postValue,
        uint256 txValue,
        address caller
    );

    function FEE_DIVISOR() external view returns (uint256);

    function DIRECTORY() external view returns (IJBDirectory);

    function FEE_PROJECT_ID() external view returns (uint256);

    function tierIdForEncodedIPFSUriOf(address hook, bytes32 encodedIPFSUri) external view returns (uint256);

    function allowanceFor(
        address hook,
        uint256 category
    )
        external
        view
        returns (
            uint256 minimumPrice,
            uint256 minimumTotalSupply,
            uint256 maximumTotalSupply,
            address[] memory allowedAddresses
        );

    function tiersFor(
        address hook,
        bytes32[] memory encodedIPFSUris
    )
        external
        view
        returns (JB721Tier[] memory tiers);

    function configurePostingCriteriaFor(CTAllowedPost[] memory allowedPosts) external;

    function mintFrom(
        IJB721TiersHook hook,
        CTPost[] memory posts,
        address nftBeneficiary,
        address feeBeneficiary,
        bytes calldata additionalPayMetadata,
        bytes calldata feeMetadata
    )
        external
        payable;
}
