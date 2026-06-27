// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member id The tier's ID.
/// @custom:member price The price to buy an NFT in this tier, in terms of the currency in its `JBInitTiersConfig`.
/// @custom:member remainingSupply The remaining number of NFTs which can be minted from this tier.
/// @custom:member initialSupply The total number of NFTs which can be minted from this tier.
/// @custom:member votingUnits The number of votes that each NFT in this tier gets.
/// @custom:member reserveFrequency The frequency at which an extra NFT is minted for the `reserveBeneficiary` from this
/// tier. With a `reserveFrequency` of 5, an extra NFT will be minted for the `reserveBeneficiary` for every 5 NFTs
/// purchased.
/// @custom:member reserveBeneficiary The address which receives any reserve NFTs from this tier.
/// @custom:member encodedIPFSUri The IPFS URI to use for each NFT in this tier.
/// @custom:member category The category that NFTs in this tier belongs to. Used to group NFT tiers.
/// @custom:member discountPercent The discount that should be applied to the tier.
/// @custom:member allowOwnerMint A boolean indicating whether the contract's owner can mint NFTs from this tier
/// on-demand.
/// @custom:member cannotBeRemoved A boolean indicating whether attempts to remove this tier will revert.
/// @custom:member cannotIncreaseDiscountPercent If the tier cannot have its discount increased.
/// @custom:member transfersPausable A boolean indicating whether transfers for NFTs in tier can be paused.
/// @custom:member resolvedUri A resolved token URI for NFTs in this tier. Only available if the NFT this tier belongs
/// to has a resolver.
struct JB721Tier {
    uint32 id;
    uint104 price;
    uint32 remainingSupply;
    uint32 initialSupply;
    uint104 votingUnits;
    uint16 reserveFrequency;
    address reserveBeneficiary;
    bytes32 encodedIPFSUri;
    uint24 category;
    uint8 discountPercent;
    bool allowOwnerMint;
    bool transfersPausable;
    bool cannotBeRemoved;
    bool cannotIncreaseDiscountPercent;
    string resolvedUri;
}
