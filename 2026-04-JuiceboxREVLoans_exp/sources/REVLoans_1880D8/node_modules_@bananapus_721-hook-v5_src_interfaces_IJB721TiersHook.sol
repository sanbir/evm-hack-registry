// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBPrices} from "@bananapus/core-v5/src/interfaces/IJBPrices.sol";
import {IJBRulesets} from "@bananapus/core-v5/src/interfaces/IJBRulesets.sol";

import {IJB721Hook} from "./IJB721Hook.sol";
import {IJB721TiersHookStore} from "./IJB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "./IJB721TokenUriResolver.sol";
import {JB721InitTiersConfig} from "../structs/JB721InitTiersConfig.sol";
import {JB721TierConfig} from "../structs/JB721TierConfig.sol";
import {JB721TiersHookFlags} from "../structs/JB721TiersHookFlags.sol";
import {JB721TiersMintReservesConfig} from "../structs/JB721TiersMintReservesConfig.sol";
import {JB721TiersSetDiscountPercentConfig} from "../structs/JB721TiersSetDiscountPercentConfig.sol";

interface IJB721TiersHook is IJB721Hook {
    event AddPayCredits(
        uint256 indexed amount, uint256 indexed newTotalCredits, address indexed account, address caller
    );
    event AddTier(uint256 indexed tierId, JB721TierConfig tier, address caller);
    event Mint(
        uint256 indexed tokenId,
        uint256 indexed tierId,
        address indexed beneficiary,
        uint256 totalAmountPaid,
        address caller
    );
    event MintReservedNft(uint256 indexed tokenId, uint256 indexed tierId, address indexed beneficiary, address caller);
    event RemoveTier(uint256 indexed tierId, address caller);
    event SetBaseUri(string indexed baseUri, address caller);
    event SetContractUri(string indexed uri, address caller);
    event SetDiscountPercent(uint256 indexed tierId, uint256 discountPercent, address caller);
    event SetEncodedIPFSUri(uint256 indexed tierId, bytes32 encodedUri, address caller);
    event SetTokenUriResolver(IJB721TokenUriResolver indexed resolver, address caller);
    event UsePayCredits(
        uint256 indexed amount, uint256 indexed newTotalCredits, address indexed account, address caller
    );

    function RULESETS() external view returns (IJBRulesets);
    function STORE() external view returns (IJB721TiersHookStore);

    function baseURI() external view returns (string memory);
    function contractURI() external view returns (string memory);
    function firstOwnerOf(uint256 tokenId) external view returns (address);
    function payCreditsOf(address addr) external view returns (uint256);
    function pricingContext() external view returns (uint256, uint256, IJBPrices);

    function adjustTiers(JB721TierConfig[] calldata tierDataToAdd, uint256[] calldata tierIdsToRemove) external;
    function initialize(
        uint256 projectId,
        string memory name,
        string memory symbol,
        string memory baseUri,
        IJB721TokenUriResolver tokenUriResolver,
        string memory contractUri,
        JB721InitTiersConfig memory tiersConfig,
        JB721TiersHookFlags memory flags
    )
        external;
    function setDiscountPercentOf(uint256 tierId, uint256 discountPercent) external;
    function setDiscountPercentsOf(JB721TiersSetDiscountPercentConfig[] calldata configs) external;
    function mintFor(uint16[] calldata tierIds, address beneficiary) external returns (uint256[] memory tokenIds);
    function mintPendingReservesFor(JB721TiersMintReservesConfig[] calldata reserveMintConfigs) external;
    function mintPendingReservesFor(uint256 tierId, uint256 count) external;
    function setMetadata(
        string calldata baseUri,
        string calldata contractMetadataUri,
        IJB721TokenUriResolver tokenUriResolver,
        uint256 encodedIPFSUriTierId,
        bytes32 encodedIPFSUri
    )
        external;
}
