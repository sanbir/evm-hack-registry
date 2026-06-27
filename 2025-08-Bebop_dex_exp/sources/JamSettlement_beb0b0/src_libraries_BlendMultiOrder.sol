// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "../interfaces/IPermit2.sol";


/// @notice Struct for many-to-one or one-to-many trade with one maker
struct BlendMultiOrder {
    uint256 expiry;
    address taker_address;
    address maker_address;
    uint256 maker_nonce;
    address[] taker_tokens;
    address[] maker_tokens;
    uint256[] taker_amounts;
    uint256[] maker_amounts;
    address receiver;
    bytes commands;
    uint256 flags;
}


library BlendMultiOrderLib {

    bytes internal constant ORDER_TYPE = abi.encodePacked(
        "MultiOrder(uint64 partner_id,uint256 expiry,address taker_address,address maker_address,uint256 maker_nonce,address[] taker_tokens,address[] maker_tokens,uint256[] taker_amounts,uint256[] maker_amounts,address receiver,bytes commands,bytes32 hooksHash)"
    );
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(ORDER_TYPE);
    string internal constant PERMIT2_ORDER_TYPE = string(
        abi.encodePacked("MultiOrder witness)", ORDER_TYPE, "TokenPermissions(address token,uint256 amount)")
    );
    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice hash the given order using same schema as in BebopBlend contract
    /// @param order the order to hash
    /// @param updatedMakerAmounts amounts that taker signed
    /// @param updatedMakerNonce nonce that taker signed
    /// @return the eip-712 order hash
    function hash(
        BlendMultiOrder memory order, uint256[] memory updatedMakerAmounts, uint256 updatedMakerNonce, bytes32 hooksHash
    ) internal pure returns (bytes32) {
        uint64 partnerId = uint64(order.flags >> 64);
        return keccak256(
            abi.encode(
                ORDER_TYPE_HASH, partnerId, order.expiry, order.taker_address, order.maker_address, updatedMakerNonce,
                keccak256(abi.encodePacked(order.taker_tokens)), keccak256(abi.encodePacked(order.maker_tokens)),
                keccak256(abi.encodePacked(order.taker_amounts)), keccak256(abi.encodePacked(updatedMakerAmounts)),
                order.receiver, keccak256(order.commands), hooksHash
            )
        );
    }

    function toBatchPermit2(BlendMultiOrder memory order) internal pure returns (IPermit2.PermitBatchTransferFrom memory) {
        IPermit2.TokenPermissions[] memory permitted = new IPermit2.TokenPermissions[](order.taker_tokens.length);
        for (uint i; i < order.taker_tokens.length; ++i) {
            permitted[i] = IPermit2.TokenPermissions(order.taker_tokens[i], order.taker_amounts[i]);
        }
        return IPermit2.PermitBatchTransferFrom(permitted, order.flags >> 128, order.expiry);
    }

    function toSignatureTransferDetails(
        BlendMultiOrder memory order, address receiver
    ) internal pure returns (IPermit2.SignatureTransferDetails[] memory) {
        IPermit2.SignatureTransferDetails[] memory details = new IPermit2.SignatureTransferDetails[](order.taker_tokens.length);
        for (uint i; i < order.taker_tokens.length; ++i) {
            details[i] = IPermit2.SignatureTransferDetails(receiver, order.taker_amounts[i]);
        }
        return details;
    }

    /// @notice Get maker tokens from the order
    /// replace all tokens with command=0x04(Commands.NATIVE_TRANSFER) with native token address
    function getMakerTokens(BlendMultiOrder memory order) internal pure returns (address[] memory makerTokens) {
        makerTokens = new address[](order.maker_tokens.length);
        for (uint i; i < order.maker_tokens.length; ++i) {
            makerTokens[i] = order.commands[i] == 0x04 ? NATIVE_TOKEN : order.maker_tokens[i];
        }
    }

}
