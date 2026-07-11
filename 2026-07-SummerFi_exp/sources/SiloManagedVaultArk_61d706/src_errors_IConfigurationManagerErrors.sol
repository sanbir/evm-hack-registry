// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IConfigurationManagerErrors
 * @dev This file contains custom error definitions for the ConfigurationManager contract.
 * @notice These custom errors provide more gas-efficient and informative error handling
 * compared to traditional require statements with string messages.
 */
interface IConfigurationManagerErrors {
    /**
     * @notice Thrown when an operation is attempted with a zero address where a non-zero address is required.
     */
    error ZeroAddress();
    /**
     * @notice Thrown when ConfigurationManager was already initialized.
     */
    error ConfigurationManagerAlreadyInitialized();

    /**
     * @notice Thrown when the Raft address is not set.
     */
    error RaftNotSet();

    /**
     * @notice Thrown when the TipJar address is not set.
     */
    error TipJarNotSet();

    /**
     * @notice Thrown when the Treasury address is not set.
     */
    error TreasuryNotSet();

    /**
     * @notice Thrown when constructor address is set to the zero address.
     */
    error AddressZero();

    /**
     * @notice Thrown when the HarborCommand address is not set.
     */
    error HarborCommandNotSet();
}
