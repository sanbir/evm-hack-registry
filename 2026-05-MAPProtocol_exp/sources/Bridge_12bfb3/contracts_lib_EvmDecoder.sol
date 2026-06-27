// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import "@mapprotocol/protocol/contracts/interface/ILightVerifier.sol";
import {MessageOutEvent, MessageInEvent} from "./Types.sol";

library EvmDecoder {
    bytes32 constant MESSAGE_OUT_TOPIC = keccak256(bytes("MessageOut(bytes32,uint256,bytes)"));
    bytes32 constant MESSAGE_RELAY_TOPIC = keccak256(bytes("MessageRelay(bytes32,uint256,bytes)"));

    uint256 constant EVM_PACK_VERSION = 0x00;
    uint256 constant RELAY_BIT_OFFSET = 64;

    function encodeMessageHeader(bool _relay, uint8 _type) internal pure returns (uint256) {
        uint256 header = EVM_PACK_VERSION << 248;
        header |= _type;
        if (_relay) {
            header |= (0x01 << RELAY_BIT_OFFSET);
        }

        return header;
    }

    function decodeMessageOut(
        ILightVerifier.txLog memory log
    ) internal pure returns (bool result, MessageOutEvent memory outEvent) {
        if (!_checkEvmPackVersion(log.data)) {
            return (false, outEvent);
        }

        outEvent.orderId = log.topics[1];
        (outEvent.fromChain, outEvent.toChain, outEvent.gasLimit) = _decodeChainAndGasLimit(uint256(log.topics[2]));
        {
            address mos;
            address token;
            address initiator;
            address from;
            uint256 header;
            (log.data) = abi.decode(log.data, (bytes));
            (header, mos, token, outEvent.amount, initiator, from, outEvent.to, outEvent.swapData) = abi.decode(
                log.data,
                (uint256, address, address, uint256, address, address, bytes, bytes)
            );
            outEvent.mos = abi.encodePacked(mos);
            outEvent.token = abi.encodePacked(token);

            outEvent.from = abi.encodePacked(from);
            outEvent.initiator = abi.encodePacked(initiator);

            outEvent.relay = (((header >> RELAY_BIT_OFFSET) & 0x01) == 0x01);
            outEvent.messageType = uint8(header & 0xFF);
        }
        return (true, outEvent);
    }

    function decodeMessageRelay(
        ILightVerifier.txLog memory log
    ) internal pure returns (bool result, MessageInEvent memory outEvent) {
        if (!_checkEvmPackVersion(log.data)) {
            return (false, outEvent);
        }

        outEvent.orderId = log.topics[1];
        (outEvent.fromChain, outEvent.toChain, outEvent.gasLimit) = _decodeChainAndGasLimit(uint256(log.topics[2]));

        uint256 header;
        address to;
        (log.data) = abi.decode(log.data, (bytes));
        (header, outEvent.mos, outEvent.token, outEvent.amount, to, outEvent.from, outEvent.swapData) = abi.decode(
            log.data,
            (uint256, address, address, uint256, address, bytes, bytes)
        );

        outEvent.messageType = uint8(header);
        outEvent.to = abi.encodePacked(to);

        return (true, outEvent);
    }

    function _checkEvmPackVersion(bytes memory payload) internal pure returns (bool) {
        uint8 version;
        assembly {
            version := byte(payload, 0)
        }

        return (version & 0xF0 == uint8(EVM_PACK_VERSION));
    }

    function _decodeChainAndGasLimit(
        uint256 chainAndGasLimit
    ) internal pure returns (uint256 fromChain, uint256 toChain, uint256 gasLimit) {
        fromChain = chainAndGasLimit >> 192;
        toChain = (chainAndGasLimit << 64) >> 192;
        gasLimit = uint256(uint64(chainAndGasLimit));
    }
}
