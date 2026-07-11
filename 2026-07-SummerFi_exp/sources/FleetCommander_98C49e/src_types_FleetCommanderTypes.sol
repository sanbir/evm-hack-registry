// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IArk} from "../interfaces/IArk.sol";

import {IFleetCommanderRewardsManager} from "../interfaces/IFleetCommanderRewardsManager.sol";
import {Percentage} from "@summerfi/percentage-solidity/contracts/Percentage.sol";

/**
 * @notice Configuration parameters for the FleetCommander contract
 */
struct FleetCommanderParams {
    string name;
    string details;
    string symbol;
    address configurationManager;
    address accessManager;
    address asset;
    uint256 initialMinimumBufferBalance;
    uint256 initialRebalanceCooldown;
    uint256 depositCap;
    Percentage initialTipRate;
}

/**
 * @title FleetConfig
 * @notice Configuration parameters for the FleetCommander contract
 * @dev This struct encapsulates the mutable configuration settings of a FleetCommander.
 *      These parameters can be updated during the contract's lifecycle to adjust its behavior.
 */
struct FleetConfig {
    /**
     * @notice The buffer Ark associated with this FleetCommander
     * @dev This Ark is used as a temporary holding area for funds before they are allocated
     *      to other Arks or when they need to be quickly accessed for withdrawals.
     */
    IArk bufferArk;
    /**
     * @notice The minimum balance that should be maintained in the buffer Ark
     * @dev This value is used to ensure there's always a certain amount of funds readily
     *      available for withdrawals or rebalancing operations. It's denominated in the
     *      smallest unit of the underlying asset (e.g., wei for ETH).
     */
    uint256 minimumBufferBalance;
    /**
     * @notice The maximum total value of assets that can be deposited into the FleetCommander
     * @dev This cap helps manage the total assets under management and can be used to
     *      implement controlled growth strategies. It's denominated in the smallest unit
     *      of the underlying asset.
     */
    uint256 depositCap;
    /**
     * @notice The maximum number of rebalance operations in a single rebalance
     */
    uint256 maxRebalanceOperations;
    /**
     * @notice The address of the staking rewards contract
     */
    address stakingRewardsManager;
}

/**
 * @notice Data structure for the rebalance event
 * @param fromArk The address of the Ark from which assets are moved
 * @param toArk The address of the Ark to which assets are moved
 * @param amount The amount of assets being moved
 * @param boardData The data to be passed to the `board` function of the `toArk`
 * @param disembarkData The data to be passed to the `disembark` function of the `fromArk`
 * @dev if the `boardData` or `disembarkData` is not needed, it should be an empty byte array
 */
struct RebalanceData {
    address fromArk;
    address toArk;
    uint256 amount;
    bytes boardData;
    bytes disembarkData;
}

/**
 * @title ArkData
 * @dev Struct to store information about an Ark.
 * This struct holds the address of the Ark and the total assets it holds.
 * @dev used in the caching mechanism for the FleetCommander
 */
struct ArkData {
    /// @notice The address of the Ark.
    address arkAddress;
    /// @notice The total assets held by the Ark.
    uint256 totalAssets;
}
