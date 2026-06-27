// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "../libraries/JamInteraction.sol";
import "../libraries/JamOrder.sol";
import "../libraries/JamHooks.sol";

interface IJamSettlement {

    /// @dev Event emitted when a settlement of JamOrder is executed successfully
    event BebopJamOrderFilled(
        uint256 indexed nonce, address indexed user, address[] sellTokens, address[] buyTokens, uint256[] sellAmounts, uint256[] buyAmounts
    );

    /// @dev Event with same eventId as will be emitted by the BebopBlend contract for SingleOrder using Order.extractEventId()
    event BebopBlendSingleOrderFilled(
        uint128 indexed eventId, address indexed receiver, address sellToken, address buyToken, uint256 sellAmount, uint256 buyAmount
    );

    /// @dev Event with same eventId as will be emitted by the BebopBlend contract for MultiOrder using Order.extractEventId()
    event BebopBlendMultiOrderFilled(
        uint128 indexed eventId, address indexed receiver, address[] sellTokens, address[] buyTokens, uint256[] sellAmounts, uint256[] buyAmounts
    );

    /// @dev Event with same eventId as will be emitted by the BebopBlend contract for AggregateOrder using Order.extractEventId()
    event BebopBlendAggregateOrderFilled(
        uint128 indexed eventId, address indexed receiver, address[] sellTokens, address[] buyTokens, uint256[] sellAmounts, uint256[] buyAmounts
    );

    /// @dev Settle a jam order.
    /// Pulls sell tokens into the contract and ensures that after running interactions receiver has the minimum of buy
    /// @param order user signed order
    /// @param signature user signature
    /// @param interactions list of interactions to settle the order
    /// @param hooksData encoded hooks for pre and post interactions, empty if no hooks
    /// @param balanceRecipient solver specifies this address to receive the initial tokens from user
    function settle(
        JamOrder calldata order,
        bytes calldata signature,
        JamInteraction.Data[] calldata interactions,
        bytes memory hooksData,
        address balanceRecipient
    ) external payable;

    /// @dev Settle a jam order without interactions, just using balance of executor
    /// @param order user signed order
    /// @param signature user signature
    /// @param filledAmounts amounts that maker is transferring to taker
    /// @param hooksData encoded hooks for pre and post interactions, empty if no hooks
    function settleInternal(
        JamOrder calldata order,
        bytes calldata signature,
        uint256[] calldata filledAmounts,
        bytes memory hooksData
    ) external payable;

    /// @dev Settle a batch of orders.
    /// Pulls sell tokens into the contract and ensures that after running interactions receivers have the minimum of buy
    /// @param orders takers signed orders
    /// @param signatures takers signatures
    /// @param interactions list of interactions to settle the order
    /// @param hooks pre and post takers interactions, if empty then no interactions are run
    /// @param balanceRecipient solver specifies this address to receive the initial tokens from users
    function settleBatch(
        JamOrder[] calldata orders,
        bytes[] calldata signatures,
        JamInteraction.Data[] calldata interactions,
        JamHooks.Def[] calldata hooks,
        address balanceRecipient
    ) external payable;

    /// @dev Execute order on BebopBlend contract
    /// Using this contract as entry point for executing BebopBlend orders
    /// @param takerAddress address of the user
    /// @param orderType type of the order, Single, Multi or Aggregate
    /// @param data encoded order data, order has same structure as in BebopBlend contract
    /// @param hooksData encoded hooks for pre and post interactions, empty if no hooks
    function settleBebopBlend(
        address takerAddress,
        IBebopBlend.BlendOrderType orderType,
        bytes memory data,
        bytes memory hooksData
    ) external payable;
}