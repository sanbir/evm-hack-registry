// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IFleetCommanderErrors
 * @dev This file contains custom error definitions for the FleetCommander contract.
 * @notice These custom errors provide more gas-efficient and informative error handling
 * compared to traditional require statements with string messages.
 */
interface IFleetCommanderErrors {
    /**
     * @notice Thrown when transfers are disabled.
     */
    error FleetCommanderTransfersDisabled();

    /**
     * @notice Thrown when an operation is attempted on an inactive Ark.
     * @param ark The address of the inactive Ark.
     */
    error FleetCommanderArkNotActive(address ark);

    /**
     * @notice Thrown when attempting to rebalance to an invalid Ark.
     * @param ark The address of the invalid Ark.
     * @param amount Amount of tokens added to target ark
     * @param effectiveDepositCap Effective deposit cap of the ark (minimum of % of fleet TVL or arbitrary ark deposit
     * cap)
     */
    error FleetCommanderEffectiveDepositCapExceeded(
        address ark,
        uint256 amount,
        uint256 effectiveDepositCap
    );

    /**
     * @notice Thrown when there is insufficient buffer for an operation.
     */
    error FleetCommanderInsufficientBuffer();

    /**
     * @notice Thrown when a rebalance operation is attempted with no actual operations.
     */
    error FleetCommanderRebalanceNoOperations();

    /**
     * @notice Thrown when a rebalance operation exceeds the maximum allowed number of operations.
     * @param operationsCount The number of operations attempted.
     */
    error FleetCommanderRebalanceTooManyOperations(uint256 operationsCount);

    /**
     * @notice Thrown when a rebalance amount for an Ark is zero.
     * @param ark The address of the Ark with zero rebalance amount.
     */
    error FleetCommanderRebalanceAmountZero(address ark);

    /**
     * @notice Thrown when a withdrawal amount exceeds the maximum buffer limit.
     */
    error WithdrawalAmountExceedsMaxBufferLimit();

    /**
     * @notice Thrown when an Ark's deposit cap is zero.
     * @param ark The address of the Ark with zero deposit cap.
     */
    error FleetCommanderArkDepositCapZero(address ark);

    /**
     * @notice Thrown when no funds were moved in an operation that expected fund movement.
     */
    error FleetCommanderNoFundsMoved();

    /**
     * @notice Thrown when there are no excess funds to perform an operation.
     */
    error FleetCommanderNoExcessFunds();

    /**
     * @notice Thrown when an invalid source Ark is specified for an operation.
     * @param ark The address of the invalid source Ark.
     */
    error FleetCommanderInvalidSourceArk(address ark);

    /**
     * @notice Thrown when an operation attempts to move more funds than available.
     */
    error FleetCommanderMovedMoreThanAvailable();

    /**
     * @notice Thrown when an unauthorized withdrawal is attempted.
     * @param caller The address attempting the withdrawal.
     * @param owner The address of the authorized owner.
     */
    error FleetCommanderUnauthorizedWithdrawal(address caller, address owner);

    /**
     * @notice Thrown when an unauthorized redemption is attempted.
     * @param caller The address attempting the redemption.
     * @param owner The address of the authorized owner.
     */
    error FleetCommanderUnauthorizedRedemption(address caller, address owner);

    /**
     * @notice Thrown when attempting to use rebalance on a buffer Ark.
     */
    error FleetCommanderCantUseRebalanceOnBufferArk();

    /**
     * @notice Thrown when attempting to use the maximum uint value for buffer adjustment from buffer.
     */
    error FleetCommanderCantUseMaxUintMovingFromBuffer();

    /**
     * @notice Thrown when a rebalance operation exceeds the maximum outflow for an Ark.
     * @param fromArk The address of the Ark from which funds are being moved.
     * @param amount The amount being moved.
     * @param maxRebalanceOutflow The maximum allowed outflow.
     */
    error FleetCommanderExceedsMaxOutflow(
        address fromArk,
        uint256 amount,
        uint256 maxRebalanceOutflow
    );

    /**
     * @notice Thrown when a rebalance operation exceeds the maximum inflow for an Ark.
     * @param fromArk The address of the Ark to which funds are being moved.
     * @param amount The amount being moved.
     * @param maxRebalanceInflow The maximum allowed inflow.
     */
    error FleetCommanderExceedsMaxInflow(
        address fromArk,
        uint256 amount,
        uint256 maxRebalanceInflow
    );

    /**
     * @notice Thrown when the staking rewards manager is not set.
     */
    error FleetCommanderStakingRewardsManagerNotSet();

    /**
     * @notice Thrown when user attempts to deposit/mint or withdraw/redeem 0 units
     */
    error FleetCommanderZeroAmount();
}
