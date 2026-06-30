// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "./base/JamTransfer.sol";
import "./interfaces/IJamBalanceManager.sol";
import "./interfaces/IPermit2.sol";

/// @title JamBalanceManager
/// @notice The reason a balance manager exists is to prevent interaction to the settlement contract draining user funds
/// By having another contract that allowances are made to, we can enforce that it is only used to draw in user balances to settlement and not sent out
contract JamBalanceManager is IJamBalanceManager {

    using SafeTransferLib for IERC20;
    using JamOrderLib for JamOrder;
    using BlendSingleOrderLib for BlendSingleOrder;
    using BlendMultiOrderLib for BlendMultiOrder;
    using BlendAggregateOrderLib for BlendAggregateOrder;

    address private immutable operator;
    IPermit2 private immutable PERMIT2;

    constructor(address _operator, address _permit2) {
        // Operator can be defined at creation time with `msg.sender`
        // Pass in the settlement - and that can be the only caller.
        operator = _operator;
        PERMIT2 = IPermit2(_permit2);
    }

    modifier onlyOperator(address account) {
        require(account == operator, InvalidCaller());
        _;
    }

    /// @inheritdoc IJamBalanceManager
    function transferTokensWithPermit2(
        JamOrder calldata order,
        bytes calldata signature,
        bytes32 hooksHash,
        address receiver
    ) onlyOperator(msg.sender) external {
        PERMIT2.permitWitnessTransferFrom(
            order.toBatchPermit2(),
            order.toSignatureTransferDetails(receiver),
            order.taker,
            order.hash(hooksHash),
            JamOrderLib.PERMIT2_ORDER_TYPE,
            signature
        );
    }

    /// @inheritdoc IJamBalanceManager
    function transferTokens(
        address[] calldata tokens,
        uint256[] calldata amounts,
        address sender,
        address receiver
    ) onlyOperator(msg.sender) external {
        for (uint i; i < tokens.length; ++i){
            if (tokens[i] != JamOrderLib.NATIVE_TOKEN){
                IERC20(tokens[i]).safeTransferFrom(sender, receiver, amounts[i]);
            } else if (receiver != operator){
                JamTransfer(operator).transferNativeFromContract(receiver, amounts[i]);
            }
        }
    }

    /// @inheritdoc IJamBalanceManager
    function transferTokenForBlendSingleOrder(
        BlendSingleOrder memory order,
        IBebopBlend.OldSingleQuote memory oldSingleQuote,
        bytes memory takerSignature,
        address takerAddress,
        bytes32 hooksHash
    ) onlyOperator(msg.sender) external {
        PERMIT2.permitWitnessTransferFrom(
            IPermit2.PermitTransferFrom(
                IPermit2.TokenPermissions(order.taker_token, order.taker_amount), order.flags >> 128, order.expiry
            ),
            IPermit2.SignatureTransferDetails(operator, order.taker_amount),
            takerAddress,
            order.hash(oldSingleQuote.makerAmount, oldSingleQuote.makerNonce, hooksHash),
            BlendSingleOrderLib.PERMIT2_ORDER_TYPE,
            takerSignature
        );
    }

    /// @inheritdoc IJamBalanceManager
    function transferTokensForMultiBebopOrder(
        BlendMultiOrder memory order,
        IBebopBlend.OldMultiQuote memory oldMultiQuote,
        bytes memory takerSignature,
        address takerAddress,
        bytes32 hooksHash
    ) onlyOperator(msg.sender) external {
        PERMIT2.permitWitnessTransferFrom(
            order.toBatchPermit2(),
            order.toSignatureTransferDetails(operator),
            takerAddress,
            order.hash(oldMultiQuote.makerAmounts, oldMultiQuote.makerNonce, hooksHash),
            BlendMultiOrderLib.PERMIT2_ORDER_TYPE,
            takerSignature
        );
    }

    /// @inheritdoc IJamBalanceManager
    function transferTokensForAggregateBebopOrder(
        BlendAggregateOrder memory order,
        IBebopBlend.OldAggregateQuote memory oldAggregateQuote,
        bytes memory takerSignature,
        address takerAddress,
        bytes32 hooksHash
    ) onlyOperator(msg.sender) external {
        (address[] memory tokens, uint256[] memory amounts) = order.unpackTokensAndAmounts(true, oldAggregateQuote);
        PERMIT2.permitWitnessTransferFrom(
            order.toBatchPermit2(tokens, amounts),
            BlendAggregateOrderLib.toSignatureTransferDetails(amounts, operator),
            takerAddress,
            order.hash(oldAggregateQuote.makerAmounts, oldAggregateQuote.makerNonces, hooksHash),
            BlendAggregateOrderLib.PERMIT2_ORDER_TYPE,
            takerSignature
        );
    }

}