// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

/**
 * @title IPoolHooks
 * @author Zentra Protocol
 * @notice Interface for Pool hook callbacks (BEFORE and AFTER)
 * @dev Implement this interface to receive callbacks for Pool operations.
 *
 *      BEFORE HOOKS (Blocking):
 *      - Called BEFORE the operation executes
 *      - Return true to allow, false to block
 *      - If hook reverts, operation is blocked (fail-closed for security)
 *      - Used for validation, access control, and security checks
 *
 *      AFTER HOOKS (Non-blocking):
 *      - Called AFTER the operation completes successfully
 *      - Wrapped in try/catch - reverts do not block the operation
 *      - Used for tracking, logging, and post-operation updates
 *
 *      This interface is implemented by SecurityIntegrationV2 to integrate
 *      bad debt detection, deficit tracking, and other security features.
 */
interface IPoolHooks {
    // ============================================================
    //                      BEFORE HOOKS
    // ============================================================

    /**
     * @notice Called before a supply operation
     * @dev Return false to block the operation. Reverts also block (fail-closed).
     * @param asset The address of the underlying asset to supply
     * @param amount The amount being supplied
     * @param onBehalfOf The address that will receive the aTokens
     * @param referralCode The referral code used (0 if none)
     * @return allowed True if the operation should proceed, false to block
     */
    function beforeSupply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external returns (bool allowed);

    /**
     * @notice Called before a borrow operation
     * @dev Return false to block the operation. Reverts also block (fail-closed).
     * @param asset The address of the underlying asset to borrow
     * @param user The address initiating the borrow (msg.sender in Pool)
     * @param onBehalfOf The address that will receive the debt
     * @param amount The amount being borrowed
     * @param interestRateMode The interest rate mode (1 = Stable, 2 = Variable)
     * @param referralCode The referral code used (0 if none)
     * @return allowed True if the operation should proceed, false to block
     */
    function beforeBorrow(
        address asset,
        address user,
        address onBehalfOf,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode
    ) external returns (bool allowed);

    /**
     * @notice Called before a liquidation operation
     * @dev Return false to block the operation. Reverts also block (fail-closed).
     * @param collateralAsset The address of the collateral asset to liquidate
     * @param debtAsset The address of the debt asset to repay
     * @param user The address of the user being liquidated
     * @param debtToCover The amount of debt to cover
     * @param receiveAToken True if liquidator wants aTokens, false for underlying
     * @return allowed True if the operation should proceed, false to block
     */
    function beforeLiquidation(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external returns (bool allowed);

    /**
     * @notice Called before a flash loan operation
     * @dev Return false to block the operation. Reverts also block (fail-closed).
     * @param receiverAddress The address of the flash loan receiver contract
     * @param assets Array of asset addresses being flash borrowed
     * @param amounts Array of amounts being flash borrowed
     * @param interestRateModes Array of interest rate modes for debt (if any)
     * @param onBehalfOf The address that will receive any opened debt
     * @param params Additional parameters passed to the receiver
     * @param referralCode The referral code used (0 if none)
     * @return allowed True if the operation should proceed, false to block
     */
    function beforeFlashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external returns (bool allowed);

    // ============================================================
    //                       AFTER HOOKS
    // ============================================================
    /**
     * @notice Called after a successful supply operation
     * @dev Called after SupplyLogic.executeSupply completes
     * @param asset The address of the underlying asset supplied
     * @param amount The amount that was supplied
     * @param onBehalfOf The address that received the aTokens
     * @param referralCode The referral code used (0 if none)
     */
    function afterSupply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /**
     * @notice Called after a successful borrow operation
     * @dev Called after BorrowLogic.executeBorrow completes
     * @param asset The address of the underlying asset borrowed
     * @param amount The amount that was borrowed
     * @param interestRateMode The interest rate mode (1 = Stable, 2 = Variable)
     * @param onBehalfOf The address that received the debt
     * @param borrower The address that initiated the borrow (msg.sender in Pool)
     * @param referralCode The referral code used (0 if none)
     */
    function afterBorrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf,
        address borrower,
        uint16 referralCode
    ) external;

    /**
     * @notice Called after a successful liquidation operation
     * @dev Called after LiquidationLogic.executeLiquidationCall completes.
     *      This is the primary hook for bad debt detection (AAVE V3.3 style).
     *      Implementation should check if user still has debt with zero collateral.
     * @param collateralAsset The address of the collateral asset liquidated
     * @param debtAsset The address of the debt asset repaid
     * @param user The address of the user being liquidated
     * @param debtToCover The amount of debt that was covered
     * @param liquidatedCollateralAmount The amount of collateral liquidated (0 if not available)
     * @param liquidator The address of the liquidator
     * @param receiveAToken True if liquidator received aTokens
     */
    function afterLiquidation(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount,
        address liquidator,
        bool receiveAToken
    ) external;

    /**
     * @notice Called after a successful flash loan operation
     * @dev Called after FlashLoanLogic.executeFlashLoan completes
     * @param receiverAddress The address that received the flash loan
     * @param assets Array of asset addresses that were borrowed
     * @param amounts Array of amounts that were borrowed
     * @param interestRateModes Array of interest rate modes for any opened debt
     * @param onBehalfOf The address that received any opened debt
     * @param referralCode The referral code used (0 if none)
     */
    function afterFlashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        uint16 referralCode
    ) external;
}
