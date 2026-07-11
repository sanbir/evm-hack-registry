// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IArkConfigProviderErrors
 * @dev This file contains custom error definitions for the ArkConfigProvider contract.
 * @notice These custom errors provide more gas-efficient and informative error handling
 * compared to traditional require statements with string messages.
 */
interface IArkConfigProviderErrors {
    /**
     * @notice Thrown when attempting to deploy an Ark without specifying a configuration manager.
     */
    error CannotDeployArkWithoutConfigurationManager();

    /**
     * @notice Thrown when attempting to deploy an Ark without specifying a Raft address.
     */
    error CannotDeployArkWithoutRaft();

    /**
     * @notice Thrown when attempting to deploy an Ark without specifying a token address.
     */
    error CannotDeployArkWithoutToken();

    /**
     * @notice Thrown when attempting to deploy an Ark with an empty name.
     */
    error CannotDeployArkWithEmptyName();

    /**
     * @notice Thrown when an invalid vault address is provided.
     */
    error InvalidVaultAddress();

    /**
     * @notice Thrown when there's a mismatch between expected and actual assets in an ERC4626 operation.
     */
    error ERC4626AssetMismatch();

    /**
     * @notice Thrown when the max deposit percentage of TVL is greater than 100%.
     */
    error MaxDepositPercentageOfTVLTooHigh();

    /**
     * @notice Thrown when attempting to register a FleetCommander when one is already registered.
     */
    error FleetCommanderAlreadyRegistered();

    /**
     * @notice Thrown when attempting to unregister a FleetCommander by a non-registered address.
     */
    error FleetCommanderNotRegistered();
}
