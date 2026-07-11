// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IArkErrors} from "../errors/IArkErrors.sol";

import {IArkEvents} from "../events/IArkEvents.sol";
import {IArkAccessManaged} from "./IArkAccessManaged.sol";
import {IArkConfigProvider} from "./IArkConfigProvider.sol";

/**
 * @title IArk
 * @notice Interface for the Ark contract, which manages funds and interacts with Rafts
 * @dev Inherits from IArkAccessManaged for access control and IArkEvents for event definitions
 */
interface IArk is
    IArkAccessManaged,
    IArkEvents,
    IArkErrors,
    IArkConfigProvider
{
    /**
     * @notice Returns the current underlying balance of the Ark
     * @return The total assets in the Ark, in token precision
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Triggers a harvest operation to collect rewards
     * @param additionalData Optional bytes that might be required by a specific protocol to harvest
     * @return rewardTokens The reward token addresses
     * @return rewardAmounts The reward amounts
     */
    function harvest(
        bytes calldata additionalData
    )
        external
        returns (address[] memory rewardTokens, uint256[] memory rewardAmounts);

    /**
     * @notice Sweeps tokens from the Ark
     * @param tokens The tokens to sweep
     * @return sweptTokens The swept tokens
     * @return sweptAmounts The swept amounts
     */
    function sweep(
        address[] calldata tokens
    )
        external
        returns (address[] memory sweptTokens, uint256[] memory sweptAmounts);

    /**
     * @notice Deposits (boards) tokens into the Ark
     * @dev This function is called by the Fleet Commander to deposit assets into the Ark.
     *      It transfers tokens from the caller to this contract and then calls the internal _board function.
     * @param amount The amount of assets to board
     * @param boardData Additional data required for boarding, specific to the Ark implementation
     * @custom:security-note This function is only callable by authorized entities
     */
    function board(uint256 amount, bytes calldata boardData) external;

    /**
     * @notice Withdraws (disembarks) tokens from the Ark
     * @param amount The amount of tokens to withdraw
     * @param disembarkData Additional data that might be required by a specific protocol to withdraw funds
     */
    function disembark(uint256 amount, bytes calldata disembarkData) external;

    /**
     * @notice Moves tokens from one ark to another
     * @param amount The amount of tokens to move
     * @param receiver The address of the Ark the funds will be boarded to
     * @param boardData Additional data that might be required by a specific protocol to board funds
     * @param disembarkData Additional data that might be required by a specific protocol to disembark funds
     */
    function move(
        uint256 amount,
        address receiver,
        bytes calldata boardData,
        bytes calldata disembarkData
    ) external;

    /**
     * @notice Internal function to get the total assets that are withdrawable
     * @return uint256 The total assets that are withdrawable
     * @dev _withdrawableTotalAssets is an internal function that should be implemented by derived contracts to define
     * specific withdrawability logic
     * @dev the ark is withdrawable if it doesnt require keeper data and _isWithdrawable returns true
     */
    function withdrawableTotalAssets() external view returns (uint256);
}
