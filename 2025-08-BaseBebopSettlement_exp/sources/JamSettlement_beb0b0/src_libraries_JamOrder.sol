// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "../interfaces/IPermit2.sol";
import "./JamHooks.sol";
import "../external-libs/PermitHash.sol";

/// @dev Data representing a Jam Order.
struct JamOrder {
    address taker;
    address receiver;
    uint256 expiry;
    uint256 exclusivityDeadline; // if block.timestamp > exclusivityDeadline, then order can be executed by any executor
    uint256 nonce;
    address executor; // only msg.sender=executor is allowed to execute (if executor=address(0), then order can be executed by anyone)
    uint256 partnerInfo; // partnerInfo is a packed struct of [partnerAddress,partnerFee,protocolFee]
    address[] sellTokens;
    address[] buyTokens;
    uint256[] sellAmounts;
    uint256[] buyAmounts;
    bool usingPermit2; // this field is excluded from ORDER_TYPE, so taker doesnt need to sign it
}


/// @title JamOrderLib
library JamOrderLib {

    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bytes internal constant ORDER_TYPE = abi.encodePacked(
        "JamOrder(address taker,address receiver,uint256 expiry,uint256 exclusivityDeadline,uint256 nonce,address executor,uint256 partnerInfo,address[] sellTokens,address[] buyTokens,uint256[] sellAmounts,uint256[] buyAmounts,bytes32 hooksHash)"
    );
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(ORDER_TYPE);
    string internal constant PERMIT2_ORDER_TYPE = string(
        abi.encodePacked("JamOrder witness)", ORDER_TYPE, "TokenPermissions(address token,uint256 amount)")
    );

    /// @notice hash the given order
    /// @param order the order to hash
    /// @return the eip-712 order hash
    function hash(JamOrder calldata order, bytes32 hooksHash) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPE_HASH, order.taker, order.receiver, order.expiry, order.exclusivityDeadline, order.nonce,
                order.executor, order.partnerInfo, keccak256(abi.encodePacked(order.sellTokens)),
                keccak256(abi.encodePacked(order.buyTokens)), keccak256(abi.encodePacked(order.sellAmounts)),
                keccak256(abi.encodePacked(order.buyAmounts)), hooksHash
            )
        );
    }

    function toBatchPermit2(JamOrder calldata order) internal pure returns (IPermit2.PermitBatchTransferFrom memory) {
        IPermit2.TokenPermissions[] memory permitted = new IPermit2.TokenPermissions[](order.sellTokens.length);
        for (uint i; i < order.sellTokens.length; ++i) {
            permitted[i] = IPermit2.TokenPermissions(order.sellTokens[i], order.sellAmounts[i]);
        }
        return IPermit2.PermitBatchTransferFrom(permitted, order.nonce, order.expiry);
    }

    function toSignatureTransferDetails(
        JamOrder calldata order, address receiver
    ) internal pure returns (IPermit2.SignatureTransferDetails[] memory details) {
        details = new IPermit2.SignatureTransferDetails[](order.sellTokens.length);
        for (uint i; i < order.sellTokens.length; ++i) {
            details[i] = IPermit2.SignatureTransferDetails(receiver, order.sellAmounts[i]);
        }
    }

    function permit2OrderHash(JamOrder calldata order, bytes32 hooksHash, address spender) internal pure returns (bytes32) {
        return PermitHash.hashWithWitness(toBatchPermit2(order), hash(order, hooksHash), PERMIT2_ORDER_TYPE, spender);
    }


}
