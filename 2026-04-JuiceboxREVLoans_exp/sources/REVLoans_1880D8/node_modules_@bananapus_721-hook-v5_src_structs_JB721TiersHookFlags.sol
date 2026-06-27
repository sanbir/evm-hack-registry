// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member noNewTiersWithReserves A boolean indicating whether attempts to add new tiers with a non-zero
/// `reserveFrequency` will revert.
/// @custom:member noNewTiersWithVotes A boolean indicating whether attempts to add new tiers with non-zero
/// `votingUnits` will revert.
/// @custom:member noNewTiersWithOwnerMinting A boolean indicating whether attempts to add new tiers with
/// `allowOwnerMint` set to true will revert.
/// @custom:member preventOverspending A boolean indicating whether payments attempting to spend more than the price of
/// the NFTs being minted will revert.
struct JB721TiersHookFlags {
    bool noNewTiersWithReserves;
    bool noNewTiersWithVotes;
    bool noNewTiersWithOwnerMinting;
    bool preventOverspending;
}
