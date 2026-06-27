// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "./base/JamValidation.sol";
import "./base/JamTransfer.sol";
import "./interfaces/IJamSettlement.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title JamSettlement
/// @notice The settlement contract executes the full lifecycle of a trade on chain.
/// Solvers figure out what "interactions" to pass to this contract such that the user order is fulfilled.
/// The contract ensures that only the user agreed price can be executed and otherwise will fail to execute.
/// As long as the trade is fulfilled, the solver is allowed to keep any potential excess.
contract JamSettlement is IJamSettlement, ReentrancyGuard, JamValidation, JamTransfer {

    address public immutable bebopBlend;
    using BlendAggregateOrderLib for BlendAggregateOrder;
    using BlendMultiOrderLib for BlendMultiOrder;

    constructor(address _permit2, address _bebopBlend, address _treasuryAddress) JamPartner(_treasuryAddress) JamValidation(_permit2) {
        bebopBlend = _bebopBlend;
    }

    receive() external payable {}


    /// @inheritdoc IJamSettlement
    function settle(
        JamOrder calldata order,
        bytes calldata signature,
        JamInteraction.Data[] calldata interactions,
        bytes memory hooksData,
        address balanceRecipient
    ) external payable nonReentrant {
        JamHooks.Def memory hooks = hooksData.length != 0 ?
            abi.decode(hooksData, (JamHooks.Def)) : JamHooks.Def(new JamInteraction.Data[](0), new JamInteraction.Data[](0));
        bytes32 hooksHash = hooksData.length != 0 ? JamHooks.hash(hooks) : JamHooks.EMPTY_HOOKS_HASH;
        validateOrder(order, signature, hooksHash);
        if (hooksHash != JamHooks.EMPTY_HOOKS_HASH){
            require(JamInteraction.runInteractionsM(hooks.beforeSettle, balanceManager), BeforeSettleHooksFailed());
        }
        if (order.usingPermit2) {
            balanceManager.transferTokensWithPermit2(order, signature, hooksHash, balanceRecipient);
        } else {
            balanceManager.transferTokens(order.sellTokens, order.sellAmounts, order.taker, balanceRecipient);
        }
        require(JamInteraction.runInteractions(interactions, balanceManager), InteractionsFailed());
        uint256[] memory buyAmounts = order.buyAmounts;
        transferTokensFromContract(order.buyTokens, order.buyAmounts, buyAmounts, order.receiver, order.partnerInfo, false);
        if (order.receiver == address(this)){
            require(!hasDuplicates(order.buyTokens), DuplicateTokens());
        }
        emit BebopJamOrderFilled(
            order.nonce, order.taker, order.sellTokens, order.buyTokens, order.sellAmounts, buyAmounts
        );
        if (hooksHash != JamHooks.EMPTY_HOOKS_HASH){
            require(JamInteraction.runInteractionsM(hooks.afterSettle, balanceManager), AfterSettleHooksFailed());
        }
    }


    /// @inheritdoc IJamSettlement
    function settleInternal(
        JamOrder calldata order,
        bytes calldata signature,
        uint256[] calldata filledAmounts,
        bytes memory hooksData
    ) external payable nonReentrant {
        JamHooks.Def memory hooks = hooksData.length != 0 ?
            abi.decode(hooksData, (JamHooks.Def)) : JamHooks.Def(new JamInteraction.Data[](0),new JamInteraction.Data[](0));
        bytes32 hooksHash = hooksData.length != 0 ? JamHooks.hash(hooks) : JamHooks.EMPTY_HOOKS_HASH;
        validateOrder(order, signature, hooksHash);
        if (hooksHash != JamHooks.EMPTY_HOOKS_HASH){
            require(JamInteraction.runInteractionsM(hooks.beforeSettle, balanceManager), BeforeSettleHooksFailed());
        }
        if (order.usingPermit2) {
            balanceManager.transferTokensWithPermit2(order, signature, hooksHash, msg.sender);
        } else {
            balanceManager.transferTokens(order.sellTokens, order.sellAmounts, order.taker, msg.sender);
        }
        if (order.partnerInfo == 0){
            uint256[] calldata buyAmounts = validateFilledAmounts(filledAmounts, order.buyAmounts);
            balanceManager.transferTokens(order.buyTokens, buyAmounts, msg.sender, order.receiver);
            emit BebopJamOrderFilled(order.nonce, order.taker, order.sellTokens, order.buyTokens, order.sellAmounts, buyAmounts);
        } else {
            (
                uint256[] memory buyAmounts, uint256[] memory protocolFees, uint256[] memory partnerFees, address partner
            ) = getUpdatedAmountsAndFees(filledAmounts, order.buyAmounts, order.partnerInfo);
            balanceManager.transferTokens(order.buyTokens, buyAmounts, msg.sender, order.receiver);
            if (protocolFees.length != 0){
                balanceManager.transferTokens(order.buyTokens, protocolFees, msg.sender, protocolFeeAddress);
            }
            if (partnerFees.length != 0){
                balanceManager.transferTokens(order.buyTokens, partnerFees, msg.sender, partner);
            }
            emit BebopJamOrderFilled(order.nonce, order.taker, order.sellTokens, order.buyTokens, order.sellAmounts, buyAmounts);
        }
        if (hooksHash != JamHooks.EMPTY_HOOKS_HASH){
            require(JamInteraction.runInteractionsM(hooks.afterSettle, balanceManager), AfterSettleHooksFailed());
        }
    }


    /// @inheritdoc IJamSettlement
    function settleBatch(
        JamOrder[] calldata orders,
        bytes[] calldata signatures,
        JamInteraction.Data[] calldata interactions,
        JamHooks.Def[] calldata hooks,
        address balanceRecipient
    ) external payable nonReentrant {
        validateBatchOrders(orders, hooks, signatures);
        bool executeHooks = hooks.length != 0;
        for (uint i; i < orders.length; ++i) {
            if (executeHooks){
                require(JamInteraction.runInteractions(hooks[i].beforeSettle, balanceManager), BeforeSettleHooksFailed());
            }
            if (orders[i].usingPermit2) {
                balanceManager.transferTokensWithPermit2(
                    orders[i], signatures[i], executeHooks ? JamHooks.hash(hooks[i]) : JamHooks.EMPTY_HOOKS_HASH, balanceRecipient
                );
            } else {
                balanceManager.transferTokens(orders[i].sellTokens, orders[i].sellAmounts, orders[i].taker, balanceRecipient);
            }
        }
        require(JamInteraction.runInteractions(interactions, balanceManager), InteractionsFailed());
        for (uint i; i < orders.length; ++i) {
            uint256[] memory buyAmounts = calculateNewAmounts(i, orders);
            transferTokensFromContract(
                orders[i].buyTokens, orders[i].buyAmounts, buyAmounts, orders[i].receiver, orders[i].partnerInfo, true
            );
            emit BebopJamOrderFilled(
                orders[i].nonce, orders[i].taker, orders[i].sellTokens, orders[i].buyTokens, orders[i].sellAmounts, buyAmounts
            );
            if (executeHooks){
                require(JamInteraction.runInteractions(hooks[i].afterSettle, balanceManager), AfterSettleHooksFailed());
            }
        }
    }


    /// @inheritdoc IJamSettlement
    function settleBebopBlend(
        address takerAddress,
        IBebopBlend.BlendOrderType orderType,
        bytes memory data,
        bytes memory hooksData
    ) external payable nonReentrant {
        JamHooks.Def memory hooks = hooksData.length != 0 ?
            abi.decode(hooksData, (JamHooks.Def)) : JamHooks.Def(new JamInteraction.Data[](0),new JamInteraction.Data[](0));
        bytes32 hooksHash = hooksData.length != 0 ? JamHooks.hash(hooks) : JamHooks.EMPTY_HOOKS_HASH;
        if (hooksHash != JamHooks.EMPTY_HOOKS_HASH){
            require(JamInteraction.runInteractionsM(hooks.beforeSettle, balanceManager), BeforeSettleHooksFailed());
        }
        if (orderType == IBebopBlend.BlendOrderType.Single){
            (
                BlendSingleOrder memory order,
                IBebopBlend.MakerSignature memory makerSignature,
                IBebopBlend.OldSingleQuote memory takerQuoteInfo,
                address makerAddress,
                uint256 newFlags,
                bytes memory takerSignature
            ) = abi.decode(data, (BlendSingleOrder, IBebopBlend.MakerSignature, IBebopBlend.OldSingleQuote, address, uint256, bytes));
            balanceManager.transferTokenForBlendSingleOrder(order, takerQuoteInfo, takerSignature, takerAddress, hooksHash);
            order.maker_address = makerAddress;
            if (newFlags != 0){
                require(uint64(order.flags >> 64) == uint64(newFlags >> 64), InvalidBlendPartnerId());
                order.flags = newFlags;
            }
            approveToken(IERC20(order.taker_token), order.taker_amount, bebopBlend);
            IBebopBlend(bebopBlend).settleSingle(order, makerSignature, 0, takerQuoteInfo, "0x");
            emit BebopBlendSingleOrderFilled(
                uint128(order.flags >> 128), order.receiver, order.taker_token,
                (order.packed_commands & 0x02) != 0 ? JamOrderLib.NATIVE_TOKEN : order.maker_token, order.taker_amount,
                takerQuoteInfo.useOldAmount ? takerQuoteInfo.makerAmount : order.maker_amount
            );
        } else if (orderType == IBebopBlend.BlendOrderType.Multi){
            (
                BlendMultiOrder memory order,
                IBebopBlend.MakerSignature memory makerSignature,
                IBebopBlend.OldMultiQuote memory takerQuoteInfo,
                address makerAddress,
                uint256 newFlags,
                bytes memory takerSignature
            ) = abi.decode(data, (BlendMultiOrder, IBebopBlend.MakerSignature, IBebopBlend.OldMultiQuote, address, uint256, bytes));
            balanceManager.transferTokensForMultiBebopOrder(order, takerQuoteInfo, takerSignature, takerAddress, hooksHash);
            order.maker_address = makerAddress;
            if (newFlags != 0){
                require(uint64(order.flags >> 64) == uint64(newFlags >> 64), InvalidBlendPartnerId());
                order.flags = newFlags;
            }
            for (uint i; i < order.taker_tokens.length; ++i) {
                approveToken(IERC20(order.taker_tokens[i]), order.taker_amounts[i], bebopBlend);
            }
            IBebopBlend(bebopBlend).settleMulti(order, makerSignature, 0, takerQuoteInfo, "0x");
            emit BebopBlendMultiOrderFilled(
                uint128(order.flags >> 128), order.receiver, order.taker_tokens, order.getMakerTokens(), order.taker_amounts,
                takerQuoteInfo.useOldAmount ? takerQuoteInfo.makerAmounts : order.maker_amounts
            );
        } else if (orderType == IBebopBlend.BlendOrderType.Aggregate){
            (
                BlendAggregateOrder memory order,
                IBebopBlend.MakerSignature[] memory makerSignatures,
                IBebopBlend.OldAggregateQuote memory takerQuoteInfo,
                uint256 newFlags,
                bytes memory takerSignature
            ) = abi.decode(data, (BlendAggregateOrder, IBebopBlend.MakerSignature[], IBebopBlend.OldAggregateQuote, uint256, bytes));
            balanceManager.transferTokensForAggregateBebopOrder(order, takerQuoteInfo, takerSignature, takerAddress, hooksHash);
            if (newFlags != 0){
                require(uint64(order.flags >> 64) == uint64(newFlags >> 64), InvalidBlendPartnerId());
                order.flags = newFlags;
            }
            (address[] memory tokens, uint256[] memory amounts) = order.unpackTokensAndAmounts(true, takerQuoteInfo);
            for (uint i; i < tokens.length; ++i) {
                approveToken(IERC20(tokens[i]), amounts[i], bebopBlend);
            }
            IBebopBlend(bebopBlend).settleAggregate(order, makerSignatures, 0, takerQuoteInfo, "0x");
            (address[] memory buyTokens, uint256[] memory buyAmounts) = order.unpackTokensAndAmounts(false, takerQuoteInfo);
            emit BebopBlendAggregateOrderFilled(
                uint128(order.flags >> 128), order.receiver, tokens, buyTokens, amounts, buyAmounts
            );
        } else {
            revert InvalidBlendOrderType();
        }
        if (hooksHash != JamHooks.EMPTY_HOOKS_HASH){
            require(JamInteraction.runInteractionsM(hooks.afterSettle, balanceManager), AfterSettleHooksFailed());
        }
    }

}