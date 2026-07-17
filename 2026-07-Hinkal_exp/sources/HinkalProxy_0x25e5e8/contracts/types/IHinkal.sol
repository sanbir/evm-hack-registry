// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.6;

import {Dimensions} from "../types/Dimensions.sol";
import {CircomData} from "../types/CircomData.sol";
import {ApprovedUtxo} from "./UTXO.sol";
import {StealthAddressStructure} from "./StealthAddressStructure.sol";

interface IHinkal {
    event ExternalActionRegistered(address externalActionAddress);

    struct ConstructorArgs {
        uint256 levels;
        address poseidon;
        address circomDataBuilderAddress;
        address erc20TokenRegistryAddress;
        address relayStoreAddress;
    }

    function bufferApprovals(
        address[] calldata approvalTargets,
        uint256[][] calldata indexes
    ) external;

    function getInteractionApprovals(
        address interaction
    ) external returns (ApprovedUtxo[] memory);

    function transact(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        Dimensions calldata dimensions,
        CircomData calldata circomData
    ) external payable;

    function prooflessDeposit(
        address[] calldata erc20Addresses,
        uint256[] calldata amounts,
        uint256[] calldata tokenIds,
        StealthAddressStructure[] calldata stealthAddressStructures
    ) external payable;
}
