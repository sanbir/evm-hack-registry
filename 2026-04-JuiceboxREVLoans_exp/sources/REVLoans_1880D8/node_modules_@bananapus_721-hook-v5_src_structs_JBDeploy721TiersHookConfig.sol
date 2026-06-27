// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JB721InitTiersConfig} from "./JB721InitTiersConfig.sol";
import {JB721TiersHookFlags} from "./JB721TiersHookFlags.sol";
import {IJB721TokenUriResolver} from "../interfaces/IJB721TokenUriResolver.sol";

/// @custom:member name The NFT collection's name.
/// @custom:member symbol The NFT collection's symbol.
/// @custom:member baseUri The URI to use as a base for full NFT URIs.
/// @custom:member tokenUriResolver The contract responsible for resolving the URI for each NFT.
/// @custom:member contractUri The URI where this contract's metadata can be found.
/// @custom:member tiersConfig The NFT tiers and pricing config to launch the hook with.
/// @custom:member reserveBeneficiary The default reserved beneficiary for all tiers.
/// @custom:member flags A set of boolean options to configure the hook with.
struct JBDeploy721TiersHookConfig {
    string name;
    string symbol;
    string baseUri;
    IJB721TokenUriResolver tokenUriResolver;
    string contractUri;
    JB721InitTiersConfig tiersConfig;
    address reserveBeneficiary;
    JB721TiersHookFlags flags;
}
