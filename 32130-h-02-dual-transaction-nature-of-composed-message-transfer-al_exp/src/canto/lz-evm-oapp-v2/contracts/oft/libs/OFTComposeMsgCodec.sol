// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library OFTComposeMsgCodec {
    uint8 private constant NONCE_OFFSET = 8;
    uint8 private constant SRC_EID_OFFSET = 12;
    uint8 private constant AMOUNT_LD_OFFSET = 44;
    uint8 private constant COMPOSE_FROM_OFFSET = 76;

    function nonce(bytes calldata message) internal pure returns (uint64) {
        return uint64(bytes8(message[:NONCE_OFFSET]));
    }

    function srcEid(bytes calldata message) internal pure returns (uint32) {
        return uint32(bytes4(message[NONCE_OFFSET:SRC_EID_OFFSET]));
    }

    function amountLD(bytes calldata message) internal pure returns (uint256) {
        return uint256(bytes32(message[SRC_EID_OFFSET:AMOUNT_LD_OFFSET]));
    }

    function composeFrom(bytes calldata message) internal pure returns (bytes32) {
        return bytes32(message[AMOUNT_LD_OFFSET:COMPOSE_FROM_OFFSET]);
    }

    function composeMsg(bytes calldata message) internal pure returns (bytes memory) {
        return message[COMPOSE_FROM_OFFSET:];
    }

    function bytes32ToAddress(bytes32 value) internal pure returns (address) {
        return address(uint160(uint256(value)));
    }

    function addressToBytes32(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }
}
