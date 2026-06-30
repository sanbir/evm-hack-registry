// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../libraries/BlendSingleOrder.sol";
import "../libraries/BlendMultiOrder.sol";
import "../libraries/BlendAggregateOrder.sol";

/// @title IBebopBlend is interface for interacting with BebopBlend contract, which aggregates PMM liquidity.
/// Swaps through that contract have zero slippage.
/// Deployed on 0xbbbbbBB520d69a9775E85b458C58c648259FAD5F
interface IBebopBlend {

    enum BlendOrderType {
        Single, // 0
        Multi, // 1
        Aggregate // 2
    }

    struct OldSingleQuote {
        bool useOldAmount;
        uint256 makerAmount;
        uint256 makerNonce;
    }

    struct OldMultiQuote {
        bool useOldAmount;
        uint256[] makerAmounts;
        uint256 makerNonce;
    }

    struct OldAggregateQuote {
        bool useOldAmount;
        uint256[][] makerAmounts;
        uint256[] makerNonces;
    }

    struct MakerSignature {
        bytes signatureBytes;
        uint256 flags;
    }


    /// @notice Maker execution of one-to-one trade with one maker
    /// @param order Single order struct
    /// @param makerSignature Maker's signature for SingleOrder
    /// @param filledTakerAmount Partially filled taker amount, 0 for full fill
    /// @param takerQuoteInfo If maker_amount has improved then it contains old quote values that taker signed,
    ///                       otherwise it contains same values as in order
    /// @param takerSignature Taker's signature to approve executing order by maker,
    ///        if taker executes order himself then signature can be '0x' (recommended to use swapSingle for this case)
    function settleSingle(
        BlendSingleOrder calldata order,
        MakerSignature calldata makerSignature,
        uint256 filledTakerAmount,
        OldSingleQuote calldata takerQuoteInfo,
        bytes calldata takerSignature
    ) external payable;

    /// @notice Maker execution of one-to-many or many-to-one trade with one maker
    /// @param order Multi order struct
    /// @param makerSignature Maker's signature for MultiOrder
    /// @param filledTakerAmount Partially filled taker amount, 0 for full fill. Many-to-one doesnt support partial fill
    /// @param takerQuoteInfo If maker_amounts have improved then it contains old quote values that taker signed,
    ///                       otherwise it contains same values as in order
    /// @param takerSignature Taker's signature to approve executing order by maker,
    ///        if taker executes order himself then signature can be '0x' (recommended to use swapMulti for this case)
    function settleMulti(
        BlendMultiOrder calldata order,
        MakerSignature calldata makerSignature,
        uint256 filledTakerAmount,
        OldMultiQuote calldata takerQuoteInfo,
        bytes calldata takerSignature
    ) external payable;

    /// @notice Maker execution of any trade with multiple makers
    /// @param order Aggregate order struct
    /// @param makersSignatures Makers signatures for MultiOrder (can be contructed as part of current AggregateOrder)
    /// @param filledTakerAmount Partially filled taker amount, 0 for full fill. Many-to-one doesnt support partial fill
    /// @param takerQuoteInfo If maker_amounts have improved then it contains old quote values that taker signed,
    ///                       otherwise it contains same values as in order
    /// @param takerSignature Taker's signature to approve executing order by maker,
    ///      if taker executes order himself then signature can be '0x' (recommended to use swapAggregate for this case)
    function settleAggregate(
        BlendAggregateOrder calldata order,
        MakerSignature[] calldata makersSignatures,
        uint256 filledTakerAmount,
        OldAggregateQuote calldata takerQuoteInfo,
        bytes calldata takerSignature
    ) external payable;
}
