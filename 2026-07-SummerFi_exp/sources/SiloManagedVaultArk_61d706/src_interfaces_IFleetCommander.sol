// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFleetCommanderErrors} from "../errors/IFleetCommanderErrors.sol";
import {IFleetCommanderEvents} from "../events/IFleetCommanderEvents.sol";
import {RebalanceData} from "../types/FleetCommanderTypes.sol";

import {IFleetCommanderConfigProvider} from "./IFleetCommanderConfigProvider.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Percentage} from "@summerfi/percentage-solidity/contracts/Percentage.sol";

/**
 * @title IFleetCommander Interface
 * @notice Interface for the FleetCommander contract, which manages asset allocation across multiple Arks
 */
interface IFleetCommander is
    IERC4626,
    IFleetCommanderEvents,
    IFleetCommanderErrors,
    IFleetCommanderConfigProvider
{
    /**
     * @notice Returns the total assets that are currently withdrawable from the FleetCommander.
     * @dev If cached data is available, it will be used. Otherwise, it will be calculated on demand (and cached)
     * @return uint256 The total amount of assets that can be withdrawn.
     */
    function withdrawableTotalAssets() external view returns (uint256);

    /**
     * @notice Returns the total assets that are managed the FleetCommander.
     * @dev If cached data is available, it will be used. Otherwise, it will be calculated on demand (and cached)
     * @return uint256 The total amount of assets that can be withdrawn.
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Returns the maximum amount of the underlying asset that can be withdrawn from the owner balance in the
     * Vault, directly from Buffer.
     * @param owner The address of the owner of the assets
     * @return uint256 The maximum amount that can be withdrawn.
     */
    function maxBufferWithdraw(address owner) external view returns (uint256);

    /**
     * @notice Returns the maximum amount of the underlying asset that can be redeemed from the owner balance in the
     * Vault, directly from Buffer.
     * @param owner The address of the owner of the assets
     * @return uint256 The maximum amount that can be redeemed.
     */
    function maxBufferRedeem(address owner) external view returns (uint256);

    /* FUNCTIONS - PUBLIC - USER */
    /**
     * @notice Deposits a specified amount of assets into the contract for a given receiver.
     * @param assets The amount of assets to be deposited.
     * @param receiver The address of the receiver who will receive the deposited assets.
     * @param referralCode An optional referral code that can be used for tracking or rewards.
     */
    function deposit(
        uint256 assets,
        address receiver,
        bytes memory referralCode
    ) external returns (uint256);

    /**
     * @notice Forces a withdrawal of assets from the FleetCommander
     * @param assets The amount of assets to forcefully withdraw
     * @param receiver The address that will receive the withdrawn assets
     * @param owner The address of the owner of the assets
     * @return shares The amount of shares redeemed
     */
    function withdrawFromArks(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    /**
     * @notice Withdraws a specified amount of assets from the FleetCommander
     * @dev This function first attempts to withdraw from the buffer. If the buffer doesn't have enough assets,
     *      it will withdraw from the arks. It also handles the case where the maximum possible amount is requested.
     * @param assets The amount of assets to withdraw. If set to type(uint256).max, it will withdraw the maximum
     * possible amount.
     * @param receiver The address that will receive the withdrawn assets
     * @param owner The address of the owner of the shares
     * @return shares The number of shares burned in exchange for the withdrawn assets
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    /**
     * @notice Redeems a specified amount of shares from the FleetCommander
     * @dev This function first attempts to redeem from the buffer. If the buffer doesn't have enough assets,
     *      it will redeem from the arks. It also handles the case where the maximum possible amount is requested.
     * @param shares The number of shares to redeem. If set to type(uint256).max, it will redeem all shares owned by the
     * owner.
     * @param receiver The address that will receive the redeemed assets
     * @param owner The address of the owner of the shares
     * @return assets The amount of assets received in exchange for the redeemed shares
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /**
     * @notice Redeems shares for assets from the FleetCommander
     * @param shares The amount of shares to redeem
     * @param receiver  The address that will receive the assets
     * @param owner The address of the owner of the shares
     * @return assets The amount of assets forcefully withdrawn
     */
    function redeemFromArks(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /**
     * @notice Redeems shares for assets directly from the Buffer
     * @param shares The amount of shares to redeem
     * @param receiver The address that will receive the assets
     * @param owner The address of the owner of the shares
     * @return assets The amount of assets redeemed
     */
    function redeemFromBuffer(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /**
     * @notice Forces a withdrawal of assets directly from the Buffer
     * @param assets The amount of assets to withdraw
     * @param receiver The address that will receive the withdrawn assets
     * @param owner The address of the owner of the assets
     * @return shares The amount of shares redeemed
     */
    function withdrawFromBuffer(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    /**
     * @notice Accrues and distributes tips
     * @return uint256 The amount of tips accrued
     */
    function tip() external returns (uint256);

    /**
     * @notice Rebalances the assets across Arks, including buffer adjustments
     * @param data Array of RebalanceData structs
     * @dev RebalanceData struct contains:
     *      - fromArk: The address of the Ark to move assets from
     *      - toArk: The address of the Ark to move assets to
     *      - amount: The amount of assets to move
     *      - boardData: Additional data for the board operation
     *      - disembarkData: Additional data for the disembark operation
     * @dev Using type(uint256).max as the amount will move all assets from the fromArk to the toArk
     * @dev For standard rebalancing:
     *      - Operations cannot involve the buffer Ark directly
     * @dev For buffer adjustments:
     *      - type(uint256).max is only allowed when moving TO the buffer
     *      - When withdrawing FROM buffer, total amount cannot reduce balance below minFundsBufferBalance
     * @dev The number of operations in a single rebalance call is limited to MAX_REBALANCE_OPERATIONS
     * @dev Rebalance is subject to a cooldown period between calls
     * @dev Only callable by accounts with the Keeper role
     */
    function rebalance(RebalanceData[] calldata data) external;

    /* FUNCTIONS - EXTERNAL - GOVERNANCE */

    /**
     * @notice Sets a new tip rate for the FleetCommander
     * @dev Only callable by the governor
     * @dev The tip rate is set as a Percentage. Percentages use 18 decimals of precision
     *      For example, for a 5% rate, you'd pass 5 * 1e18 (5 000 000 000 000 000 000)
     * @param newTipRate The new tip rate as a Percentage
     */
    function setTipRate(Percentage newTipRate) external;

    /**
     * @notice Sets a new minimum pause time for the FleetCommander
     * @dev Only callable by the governor
     * @param newMinimumPauseTime The new minimum pause time in seconds
     */
    function setMinimumPauseTime(uint256 newMinimumPauseTime) external;

    /**
     * @notice Updates the rebalance cooldown period
     * @param newCooldown The new cooldown period in seconds
     */
    function updateRebalanceCooldown(uint256 newCooldown) external;

    /**
     * @notice Forces a rebalance operation
     * @param data Array of typed rebalance data struct
     * @dev has no cooldown enforced but only callable by privileged role
     */
    function forceRebalance(RebalanceData[] calldata data) external;

    /**
     * @notice Pauses the FleetCommander
     * @dev This function is used to pause the FleetCommander in case of critical issues or emergencies
     * @dev Only callable by the guardian or governor
     */
    function pause() external;

    /**
     * @notice Unpauses the FleetCommander
     * @dev This function is used to resume normal operations after a pause
     * @dev Only callable by the guardian or governor
     */
    function unpause() external;
}
