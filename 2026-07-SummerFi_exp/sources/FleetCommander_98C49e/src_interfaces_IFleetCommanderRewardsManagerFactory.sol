// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IFleetCommanderRewardsManagerFactory
 * @notice Interface for the FleetCommanderRewardsManagerFactory contract
 * @dev Defines the interface for creating new FleetCommanderRewardsManager instances
 */
interface IFleetCommanderRewardsManagerFactory {
    /**
     * @notice Event emitted when a new rewards manager is created
     * @param rewardsManager Address of the newly created rewards manager
     * @param fleetCommander Address of the fleet commander associated with the rewards manager
     */
    event RewardsManagerCreated(
        address indexed rewardsManager,
        address indexed fleetCommander
    );

    /**
     * @notice Creates a new FleetCommanderRewardsManager instance
     * @param accessManager Address of the access manager to associate with the rewards manager
     * @param fleetCommander Address of the fleet commander to associate with the rewards manager
     * @return Address of the newly created rewards manager
     */
    function createRewardsManager(
        address accessManager,
        address fleetCommander
    ) external returns (address);
}
