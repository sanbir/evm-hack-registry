// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {IAccessToken} from "./IAccessToken.sol";
import {IRelayStore} from "./IRelayStore.sol";
import {Dimensions} from "./Dimensions.sol";
import {CircomData} from "./CircomData.sol";
import {IERC20TokenRegistry} from "./IERC20TokenRegistry.sol";
import {StealthAddressStructure} from "./StealthAddressStructure.sol";
interface IHinkalHelper is IRelayStore, IERC20TokenRegistry {
    function accessToken() external view returns (IAccessToken);

    function relayerIsValid(address relay) external view;

    function checkTokenRegistry(
        address[] calldata erc20TokenAddresses,
        int256[] calldata amountChanges
    ) external view returns (bool);

    function performHinkalChecks(
        CircomData calldata circomData,
        Dimensions calldata dimensions,
        address sender
    ) external view returns (uint256[] memory);

    function performProoflessDepositChecks(
        address[] calldata erc20Addresses,
        uint256[] calldata amounts,
        uint256[] calldata tokenIds,
        StealthAddressStructure[] calldata stealthAddressStructures
    ) external view returns (bool);

    function performSideEffects(CircomData calldata circomData) external;
}
