// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IConfigurationManagerEvents
 * @notice Interface for events emitted by the Configuration Manager
 */
interface IConfigurationManagerEvents {
    /**
     * @notice Emitted when the Raft address is updated
     * @param newRaft The address of the new Raft
     */
    event RaftUpdated(address oldRaft, address newRaft);

    /**
     * @notice Emitted when the tip jar address is updated
     * @param newTipJar The address of the new tip jar
     */
    event TipJarUpdated(address oldTipJar, address newTipJar);

    /**
     * @notice Emitted when the tip rate is updated
     * @param newTipRate The new tip rate value
     */
    event TipRateUpdated(uint8 oldTipRate, uint8 newTipRate);

    /**
     * @notice Emitted when the Treasury address is updated
     * @param newTreasury The address of the new Treasury
     */
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    /**
     * @notice Emitted when the Harbor Command address is updated
     * @param oldHarborCommand The address of the old Harbor Command
     * @param newHarborCommand The address of the new Harbor Command
     */
    event HarborCommandUpdated(
        address oldHarborCommand,
        address newHarborCommand
    );

    /**
     * @notice Emitted when the Fleet Commander Rewards Manager Factory address is updated
     * @param oldFleetCommanderRewardsManagerFactory The address of the old Fleet Commander Rewards Manager Factory
     * @param newFleetCommanderRewardsManagerFactory The address of the new Fleet Commander Rewards Manager Factory
     */
    event FleetCommanderRewardsManagerFactoryUpdated(
        address oldFleetCommanderRewardsManagerFactory,
        address newFleetCommanderRewardsManagerFactory
    );
}
