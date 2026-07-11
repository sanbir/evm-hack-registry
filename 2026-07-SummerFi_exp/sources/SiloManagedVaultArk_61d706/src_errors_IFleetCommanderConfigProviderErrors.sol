// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IFleetCommanderConfigProviderErrors
 * @dev This file contains custom error definitions for the FleetCommanderConfigProvider contract.
 * @notice These custom errors provide more gas-efficient and informative error handling
 * compared to traditional require statements with string messages.
 */
interface IFleetCommanderConfigProviderErrors {
    /**
     * @notice Thrown when an operation is attempted on a non-existent Ark
     * @param ark The address of the Ark that was not found
     */
    error FleetCommanderArkNotFound(address ark);

    /**
     * @notice Thrown when trying to remove an Ark that still has a non-zero deposit cap
     * @param ark The address of the Ark with a non-zero deposit cap
     */
    error FleetCommanderArkDepositCapGreaterThanZero(address ark);

    /**
     * @notice Thrown when attempting to remove an Ark that still holds assets
     * @param ark The address of the Ark with non-zero assets
     */
    error FleetCommanderArkAssetsNotZero(address ark);

    /**
     * @notice Thrown when trying to add an Ark that already exists in the system
     * @param ark The address of the Ark that already exists
     */
    error FleetCommanderArkAlreadyExists(address ark);

    /**
     * @notice Thrown when an invalid Ark address is provided (e.g., zero address)
     */
    error FleetCommanderInvalidArkAddress();

    /**
     * @notice Thrown when trying to set a StakingRewardsManager to the zero address
     */
    error FleetCommanderInvalidStakingRewardsManager();

    /**
     * @notice Thrown when trying to set a max rebalance operations to a value greater than the max allowed
     * @param newMaxRebalanceOperations The new max rebalance operations value
     */
    error FleetCommanderMaxRebalanceOperationsTooHigh(
        uint256 newMaxRebalanceOperations
    );

    /**
     * @notice Thrown when the asset of the Ark does not match the asset of the FleetCommander
     */
    error FleetCommanderAssetMismatch();
}
