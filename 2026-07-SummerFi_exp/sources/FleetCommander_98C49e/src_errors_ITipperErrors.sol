// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ITipperErrors
 * @dev This file contains custom error definitions for the Tipper contract.
 * @notice These custom errors provide more gas-efficient and informative error handling
 * compared to traditional require statements with string messages.
 */
interface ITipperErrors {
    /**
     * @notice Thrown when an invalid FleetCommander address is provided.
     */
    error InvalidFleetCommanderAddress();

    /**
     * @notice Thrown when an invalid TipJar address is provided.
     */
    error InvalidTipJarAddress();

    /**
     * @notice Thrown when the tip rate exceeds 5%.
     */
    error TipRateCannotExceedFivePercent();
}
