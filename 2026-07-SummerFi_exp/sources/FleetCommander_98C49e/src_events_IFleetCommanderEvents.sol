// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RebalanceData} from "../types/FleetCommanderTypes.sol";

interface IFleetCommanderEvents {
    /* EVENTS */
    /**
     * @notice Emitted when a rebalance operation is completed
     * @param keeper The address of the keeper who initiated the rebalance
     * @param rebalances An array of RebalanceData structs detailing the rebalance operations
     */
    event Rebalanced(address indexed keeper, RebalanceData[] rebalances);

    /**
     * @notice Emitted when queued funds are committed
     * @param keeper The address of the keeper who committed the funds
     * @param prevBalance The previous balance before committing funds
     * @param newBalance The new balance after committing funds
     */
    event QueuedFundsCommitted(
        address indexed keeper,
        uint256 prevBalance,
        uint256 newBalance
    );

    /**
     * @notice Emitted when the funds queue is refilled
     * @param keeper The address of the keeper who initiated the queue refill
     * @param prevBalance The previous balance before refilling
     * @param newBalance The new balance after refilling
     */
    event FundsQueueRefilled(
        address indexed keeper,
        uint256 prevBalance,
        uint256 newBalance
    );

    /**
     * @notice Emitted when the minimum balance of the funds queue is updated
     * @param keeper The address of the keeper who updated the minimum balance
     * @param newBalance The new minimum balance
     */
    event MinFundsQueueBalanceUpdated(
        address indexed keeper,
        uint256 newBalance
    );

    /**
     * @notice Emitted when the fee address is updated
     * @param newAddress The new fee address
     */
    event FeeAddressUpdated(address newAddress);

    /**
     * @notice Emitted when the funds buffer balance is updated
     * @param user The address of the user who triggered the update
     * @param prevBalance The previous buffer balance
     * @param newBalance The new buffer balance
     */
    event FundsBufferBalanceUpdated(
        address indexed user,
        uint256 prevBalance,
        uint256 newBalance
    );

    /**
     * @notice Emitted when funds are withdrawn from Arks
     * @param owner The address of the owner who initiated the withdrawal
     * @param receiver The address of the receiver of the withdrawn funds
     * @param totalWithdrawn The total amount of funds withdrawn
     */
    event FleetCommanderWithdrawnFromArks(
        address indexed owner,
        address receiver,
        uint256 totalWithdrawn
    );

    /**
     * @notice Emitted when funds are redeemed from Arks
     * @param owner The address of the owner who initiated the redemption
     * @param receiver The address of the receiver of the redeemed funds
     * @param totalRedeemed The total amount of funds redeemed
     */
    event FleetCommanderRedeemedFromArks(
        address indexed owner,
        address receiver,
        uint256 totalRedeemed
    );
    /**
     * @notice Emitted when referee deposits into the FleetCommander
     * @param referee The address of the referee who was referred
     * @param referralCode The referral code of the referrer
     */
    event FleetCommanderReferral(
        address indexed referee,
        bytes indexed referralCode
    );
}
