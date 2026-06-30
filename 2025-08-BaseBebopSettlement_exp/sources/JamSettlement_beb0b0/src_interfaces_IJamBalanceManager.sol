// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "../libraries/JamOrder.sol";
import "../libraries/BlendSingleOrder.sol";
import "../libraries/BlendMultiOrder.sol";
import "../libraries/BlendAggregateOrder.sol";
import "./IBebopBlend.sol";

/// @title IJamBalanceManager
/// @notice User approvals are made here. This handles the complexity of multiple allowance types. 
interface IJamBalanceManager {

    /// @dev Transfer user's tokens to receiver address for JamOrder
    /// @param order user signed order
    /// @param signature permit2 signature with order as witness
    /// @param hooksHash hash of hooks data
    /// @param receiver address to receive tokens, it can be operator address or solver address
    function transferTokensWithPermit2(
        JamOrder calldata order,
        bytes calldata signature,
        bytes32 hooksHash,
        address receiver
    ) external;

    /// @dev Transfer tokens to receiver address
    /// this function can be used not only for user's tokens, but also for maker's tokens in settleInternal
    /// @param tokens list of tokens to transfer
    /// @param amounts list of amounts to transfer
    /// @param sender address to transfer tokens from
    /// @param receiver address to transfer tokens to
    function transferTokens(
        address[] calldata tokens,
        uint256[] calldata amounts,
        address sender,
        address receiver
    ) external;

    /// @dev Transfer user's tokens to operator address for BlendSingleOrder
    /// @param order user signed order
    /// @param oldSingleQuote in case of amounts improvement, old quote is used to get old amounts signed by user
    /// @param takerSignature permit2 signature with order as witness
    /// @param takerAddress user address
    /// @param hooksHash hash of hooks data
    function transferTokenForBlendSingleOrder(
        BlendSingleOrder memory order,
        IBebopBlend.OldSingleQuote memory oldSingleQuote,
        bytes memory takerSignature,
        address takerAddress,
        bytes32 hooksHash
    ) external;

    /// @dev Transfer user's tokens to operator address for BlendMultiOrder
    /// @param order user signed order
    /// @param oldMultiQuote in case of amounts improvement, old quote is used to get old amounts signed by user
    /// @param takerSignature permit2 signature with order as witness
    /// @param takerAddress user address
    /// @param hooksHash hash of hooks data
    function transferTokensForMultiBebopOrder(
        BlendMultiOrder memory order,
        IBebopBlend.OldMultiQuote memory oldMultiQuote,
        bytes memory takerSignature,
        address takerAddress,
        bytes32 hooksHash
    ) external;

    /// @dev Transfer user's tokens to operator address for BlendAggregateOrder
    /// @param order user signed order
    /// @param oldAggregateQuote in case of amounts improvement, old quote is used to get old amounts signed by user
    /// @param takerSignature permit2 signature with order as witness
    /// @param takerAddress user address
    /// @param hooksHash hash of hooks data
    function transferTokensForAggregateBebopOrder(
        BlendAggregateOrder memory order,
        IBebopBlend.OldAggregateQuote memory oldAggregateQuote,
        bytes memory takerSignature,
        address takerAddress,
        bytes32 hooksHash
    ) external;

}