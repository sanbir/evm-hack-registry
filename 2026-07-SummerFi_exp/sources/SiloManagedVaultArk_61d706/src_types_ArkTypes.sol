// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Percentage} from "@summerfi/percentage-solidity/contracts/Percentage.sol";

/**
 * @title ArkParams
 * @notice Constructor parameters for the Ark contract
 *
 *  @dev This struct is used to initialize an Ark contract with all necessary parameters
 */
struct ArkParams {
    /**
     * @notice The name of the Ark
     * @dev This should be a unique, human-readable identifier for the Ark
     */
    string name;
    /**
     * @notice Additional details about the Ark
     * @dev This can be used to store additional information about the Ark
     */
    string details;
    /**
     * @notice The address of the access manager contract
     * @dev This contract manages roles and permissions for the Ark
     */
    address accessManager;
    /**
     * @notice The address of the configuration manager contract
     * @dev This contract stores global configuration parameters
     */
    address configurationManager;
    /**
     * @notice The address of the ERC20 token managed by this Ark
     * @dev This is the underlying asset that the Ark will handle
     */
    address asset;
    /**
     * @notice The maximum amount of tokens that can be deposited into the Ark
     * @dev This cap helps to manage risk and exposure
     */
    uint256 depositCap;
    /**
     * @notice The maximum amount of tokens that can be moved from this Ark in a single transaction
     * @dev This limit helps to prevent large, sudden outflows
     */
    uint256 maxRebalanceOutflow;
    /**
     * @notice The maximum amount of tokens that can be moved to this Ark in a single transaction
     * @dev This limit helps to prevent large, sudden inflows
     */
    uint256 maxRebalanceInflow;
    /**
     * @notice Whether the Ark requires Keepr data to be passed in with rebalance transactions
     * @dev This flag is used to determine whether Keepr data is required for rebalance transactions
     */
    bool requiresKeeperData;
    /**
     * @notice The maximum percentage of Total Value Locked (TVL) that can be deposited into this Ark
     * @dev This value is represented as a percentage with 18 decimal places (1e18 = 100%)
     *      For example, 0.5e18 represents 50% of TVL
     */
    Percentage maxDepositPercentageOfTVL;
}

/**
 * @title ArkConfig
 * @notice Configuration of the Ark contract
 * @dev This struct stores the current configuration of an Ark, which can be updated during its lifecycle
 */
struct ArkConfig {
    /**
     * @notice The address of the commander (typically a FleetCommander contract)
     * @dev The commander has special permissions to manage the Ark
     */
    address commander;
    /**
     * @notice The address of the associated Raft contract
     * @dev The Raft contract handles reward distribution and other protocol-wide functions
     */
    address raft;
    /**
     * @notice The ERC20 token interface for the asset managed by this Ark
     * @dev This allows direct interaction with the token contract
     */
    IERC20 asset;
    /**
     * @notice The current maximum amount of tokens that can be deposited into the Ark
     * @dev This can be adjusted by the commander to manage capacity
     */
    uint256 depositCap;
    /**
     * @notice The current maximum amount of tokens that can be moved from this Ark in a single transaction
     * @dev This can be adjusted to manage liquidity and risk
     */
    uint256 maxRebalanceOutflow;
    /**
     * @notice The current maximum amount of tokens that can be moved to this Ark in a single transaction
     * @dev This can be adjusted to manage inflows and capacity
     */
    uint256 maxRebalanceInflow;
    /**
     * @notice The name of the Ark
     * @dev This is typically set at initialization and not changed
     */
    string name;
    /**
     * @notice Additional details about the Ark
     * @dev This can be used to store additional information about the Ark
     */
    string details;
    /**
     * @notice Whether the Ark requires Keeper data to be passed in with rebalance transactions
     * @dev This flag is used to determine whether Keeper data is required for rebalance transactions
     */
    bool requiresKeeperData;
    /**
     * @notice The maximum percentage of Total Value Locked (TVL) that can be deposited into this Ark
     * @dev This value is represented as a percentage with 18 decimal places (1e18 = 100%)
     *      For example, 0.5e18 represents 50% of TVL
     */
    Percentage maxDepositPercentageOfTVL;
}
