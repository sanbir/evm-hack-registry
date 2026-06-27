// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "../interfaces/IPermit2.sol";


/// @notice BebopBlend struct for one-to-one trade with one maker
struct BlendSingleOrder {
    uint256 expiry;
    address taker_address;
    address maker_address;
    uint256 maker_nonce;
    address taker_token;
    address maker_token;
    uint256 taker_amount;
    uint256 maker_amount;
    address receiver;
    uint256 packed_commands;
    uint256 flags;
}


library BlendSingleOrderLib {

    bytes internal constant ORDER_TYPE = abi.encodePacked(
        "SingleOrder(uint64 partner_id,uint256 expiry,address taker_address,address maker_address,uint256 maker_nonce,address taker_token,address maker_token,uint256 taker_amount,uint256 maker_amount,address receiver,uint256 packed_commands,bytes32 hooksHash)"
    );
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(ORDER_TYPE);
    string internal constant PERMIT2_ORDER_TYPE = string(
        abi.encodePacked("SingleOrder witness)", ORDER_TYPE, "TokenPermissions(address token,uint256 amount)")
    );

    /// @notice hash the given order using same schema as in BebopBlend contract
    /// @param order the order to hash
    /// @param updatedMakerAmount amount that taker signed
    /// @param updatedMakerNonce nonce that taker signed
    /// @return the eip-712 order hash
    function hash(
        BlendSingleOrder memory order, uint256 updatedMakerAmount, uint256 updatedMakerNonce, bytes32 hooksHash
    ) internal pure returns (bytes32) {
        uint64 partnerId = uint64(order.flags >> 64);
        return keccak256(
            abi.encode(
                ORDER_TYPE_HASH, partnerId, order.expiry, order.taker_address, order.maker_address,
                updatedMakerNonce, order.taker_token, order.maker_token, order.taker_amount,
                updatedMakerAmount, order.receiver, order.packed_commands, hooksHash
            )
        );
    }

}
