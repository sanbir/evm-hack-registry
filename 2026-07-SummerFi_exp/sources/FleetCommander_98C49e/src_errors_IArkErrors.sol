// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IArkErrors
 * @dev This file contains custom error definitions for the Ark contract.
 * @notice These custom errors provide more gas-efficient and informative error handling
 * compared to traditional require statements with string messages.
 */
interface IArkErrors {
    /**
     * @notice Thrown when attempting to remove a commander from an Ark that still has assets.
     */
    error CannotRemoveCommanderFromArkWithAssets();

    /**
     * @notice Thrown when trying to add a commander to an Ark that already has one.
     */
    error CannotAddCommanderToArkWithCommander();

    /**
     * @notice Thrown when attempting to use keeper data when it's not required.
     */
    error CannotUseKeeperDataWhenNotRequired();

    /**
     * @notice Thrown when keeper data is required but not provided.
     */
    error KeeperDataRequired();

    /**
     * @notice Thrown when invalid board data is provided.
     */
    error InvalidBoardData();

    /**
     * @notice Thrown when invalid disembark data is provided.
     */
    error InvalidDisembarkData();
}
