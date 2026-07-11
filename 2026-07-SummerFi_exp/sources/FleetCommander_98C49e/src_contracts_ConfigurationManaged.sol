// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IConfigurationManaged} from "../interfaces/IConfigurationManaged.sol";
import {IConfigurationManager} from "../interfaces/IConfigurationManager.sol";

/**
 * @title ConfigurationManaged
 * @notice Base contract for contracts that need to read from the ConfigurationManager
 * @custom:see IConfigurationManaged
 */
abstract contract ConfigurationManaged is IConfigurationManaged {
    IConfigurationManager public immutable configurationManager;

    /**
     * @notice Constructs the ConfigurationManaged contract
     * @param _configurationManager The address of the ConfigurationManager contract
     */
    constructor(address _configurationManager) {
        if (_configurationManager == address(0)) {
            revert ConfigurationManagerZeroAddress();
        }
        configurationManager = IConfigurationManager(_configurationManager);
    }

    /// @inheritdoc IConfigurationManaged
    function raft() public view virtual returns (address) {
        return configurationManager.raft();
    }

    /// @inheritdoc IConfigurationManaged
    function tipJar() public view virtual returns (address) {
        return configurationManager.tipJar();
    }

    /// @inheritdoc IConfigurationManaged
    function treasury() public view virtual returns (address) {
        return configurationManager.treasury();
    }

    /// @inheritdoc IConfigurationManaged
    function harborCommand() public view virtual returns (address) {
        return configurationManager.harborCommand();
    }

    /// @inheritdoc IConfigurationManaged
    function fleetCommanderRewardsManagerFactory()
        public
        view
        virtual
        returns (address)
    {
        return configurationManager.fleetCommanderRewardsManagerFactory();
    }
}
