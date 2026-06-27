// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Config for a single NFT tier within a `JB721TiersHook`.
/// @custom:member price The price to buy an NFT in this tier, in terms of the currency in its `JBInitTiersConfig`.
/// @custom:member initialSupply The total number of NFTs which can be minted from this tier.
/// @custom:member votingUnits The number of votes that each NFT in this tier gets if `useVotingUnits` is true.
/// @custom:member reserveFrequency The frequency at which an extra NFT is minted for the `reserveBeneficiary` from this
/// tier. With a `reserveFrequency` of 5, an extra NFT will be minted for the `reserveBeneficiary` for every 5 NFTs
/// purchased.
/// @custom:member reserveBeneficiary The address which receives any reserve NFTs from this tier. Overrides the default
/// reserve beneficiary if one is set.
/// @custom:member encodedIPFSUri The IPFS URI to use for each NFT in this tier.
/// @custom:member category The category that NFTs in this tier belongs to. Used to group NFT tiers.
/// @custom:member discountPercent The discount that should be applied to the tier.
/// @custom:member allowOwnerMint A boolean indicating whether the contract's owner can mint NFTs from this tier
/// on-demand.
/// @custom:member useReserveBeneficiaryAsDefault A boolean indicating whether this tier's `reserveBeneficiary` should
/// be stored as the default beneficiary for all tiers.
/// @custom:member transfersPausable A boolean indicating whether transfers for NFTs in tier can be paused.
/// @custom:member useVotingUnits A boolean indicating whether the `votingUnits` should be used to calculate voting
/// power. If `useVotingUnits` is false, voting power is based on the tier's price.
/// @custom:member cannotBeRemoved If the tier cannot be removed once added.
/// @custom:member cannotIncreaseDiscount If the tier cannot have its discount increased.
struct JB721TierConfig {
    uint104 price;
    uint32 initialSupply;
    uint32 votingUnits;
    uint16 reserveFrequency;
    address reserveBeneficiary;
    bytes32 encodedIPFSUri;
    uint24 category;
    uint8 discountPercent;
    bool allowOwnerMint;
    bool useReserveBeneficiaryAsDefault;
    bool transfersPausable;
    bool useVotingUnits;
    bool cannotBeRemoved;
    bool cannotIncreaseDiscountPercent;
}
