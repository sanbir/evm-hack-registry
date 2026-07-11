// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IConfigurationManager} from "./IConfigurationManager.sol";

/**
 * @title IConfigurationManaged
 * @notice Interface for contracts that need to read from the ConfigurationManager
 * @dev This interface defines the standard methods for accessing configuration values
 *      from the ConfigurationManager. It should be implemented by contracts that
 *      need to read these configurations.
 */
interface IConfigurationManaged {
    /**
     * @notice Gets the address of the ConfigurationManager contract
     * @return The address of the ConfigurationManager contract
     */
    function configurationManager()
        external
        view
        returns (IConfigurationManager);

    /**
     * @notice Gets the address of the Raft contract
     * @return The address of the Raft contract
     */
    function raft() external view returns (address);

    /**
     * @notice Gets the address of the TipJar contract
     * @return The address of the TipJar contract
     */
    function tipJar() external view returns (address);

    /**
     * @notice Gets the address of the Treasury contract
     * @return The address of the Treasury contract
     */
    function treasury() external view returns (address);

    /**
     * @notice Gets the address of the HarborCommand contract
     * @return The address of the HarborCommand contract
     */
    function harborCommand() external view returns (address);

    /**
     * @notice Gets the address of the Fleet Commander Rewards Manager Factory contract
     * @return The address of the Fleet Commander Rewards Manager Factory contract
     */
    function fleetCommanderRewardsManagerFactory()
        external
        view
        returns (address);

    error ConfigurationManagerZeroAddress();
}
