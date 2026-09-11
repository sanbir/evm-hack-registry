// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CallDataRLPReader.sol";
import "./Utils.sol";
import "../interfaces/IInceptionBridge.sol";

library EthereumVerifier {
    bytes32 constant TOPIC_DEPOSITED =
        keccak256(
            "Deposited(uint256,address,address,address,address,address,uint256,uint256,(bytes32,bytes32,uint256,address))"
        );

    enum DepositType {
        None,
        TokenDeposit
    }

    struct State {
        bytes32 receiptHash;
        address contractAddress;
        address destinationContract;
        uint256 chainId;
        address sender;
        address receiver;
        address fromToken;
        address toToken;
        uint256 amount;
        uint256 nonce;
        // metadata fields (we can't use Metadata struct here because of Solidity struct memory layout)
        bytes32 symbol;
        bytes32 name;
        uint256 originChain;
        address originToken;
    }

    function getMetadata(
        State memory state
    ) internal pure returns (IInceptionBridgeStorage.Metadata memory) {
        IInceptionBridgeStorage.Metadata memory metadata;
        assembly {
            metadata := add(state, 0x120)
        }
        return metadata;
    }

    function parseTransactionReceipt(
        uint256 receiptOffset
    ) internal pure returns (State memory state, DepositType depositType) {
        uint256 iter = CallDataRLPReader.beginIteration(receiptOffset + 0x20);
        {
            /* postStateOrStatus - we must ensure that tx is not reverted */
            uint256 statusOffset = iter;
            iter = CallDataRLPReader.next(iter);
            require(
                CallDataRLPReader.payloadLen(
                    statusOffset,
                    iter - statusOffset
                ) == 1,
                "EthereumVerifier: tx is reverted"
            );
        }
        /* skip cumulativeGasUsed */
        iter = CallDataRLPReader.next(iter);
        /* logs - we need to find our logs */
        uint256 logs = iter;
        iter = CallDataRLPReader.next(iter);
        uint256 logsIter = CallDataRLPReader.beginIteration(logs);
        for (; logsIter < iter; ) {
            uint256 log = logsIter;
            logsIter = CallDataRLPReader.next(logsIter);
            /* make sure there is only one peg-in event in logs */
            DepositType logType = _decodeReceiptLogs(state, log);
            if (logType != DepositType.None) {
                require(
                    depositType == DepositType.None,
                    "EthereumVerifier: multiple logs"
                );
                depositType = logType;
            }
        }
        /* don't allow to process if peg-in type is unknown */
        require(
            depositType != DepositType.None,
            "EthereumVerifier: missing logs"
        );
        return (state, depositType);
    }

    function _decodeReceiptLogs(
        State memory state,
        uint256 log
    ) internal pure returns (DepositType depositType) {
        uint256 logIter = CallDataRLPReader.beginIteration(log);
        address contractAddress;
        {
            /* parse smart contract address */
            uint256 addressOffset = logIter;
            logIter = CallDataRLPReader.next(logIter);
            contractAddress = CallDataRLPReader.receiver(addressOffset);
        }
        /* topics */
        bytes32 mainTopic;
        address destinationContract;
        address sender;
        address receiver;
        {
            uint256 topicsIter = logIter;
            logIter = CallDataRLPReader.next(logIter);
            // Must be 4 topics RLP encoded: event signature, destinationContract, sender, receiver
            // Each topic RLP encoded is 33 bytes (0xa0[32 bytes data])
            // Total payload: 132 bytes. Since it's list with total size bigger than 55 bytes we need 2 bytes prefix (0xf863)
            // So total size of RLP encoded topics array must be 134
            if (CallDataRLPReader.itemLength(topicsIter) != 134) {
                return DepositType.None;
            }
            topicsIter = CallDataRLPReader.beginIteration(topicsIter);
            mainTopic = bytes32(CallDataRLPReader.toUintStrict(topicsIter));
            topicsIter = CallDataRLPReader.next(topicsIter);
            destinationContract = address(
                bytes20(uint160(CallDataRLPReader.toUintStrict(topicsIter)))
            );
            topicsIter = CallDataRLPReader.next(topicsIter);
            sender = address(
                bytes20(uint160(CallDataRLPReader.toUintStrict(topicsIter)))
            );
            topicsIter = CallDataRLPReader.next(topicsIter);
            receiver = address(
                bytes20(uint160(CallDataRLPReader.toUintStrict(topicsIter)))
            );
            topicsIter = CallDataRLPReader.next(topicsIter);
            require(topicsIter == logIter); // safety check that iteration is finished
        }

        uint256 ptr = CallDataRLPReader.rawDataPtr(logIter);
        logIter = CallDataRLPReader.next(logIter);
        uint256 len = logIter - ptr;
        {
            // parse logs based on topic type and check that event data has correct length
            uint256 expectedLen;
            if (mainTopic == TOPIC_DEPOSITED) {
                expectedLen = 0x120;
                depositType = DepositType.TokenDeposit;
            } else {
                return DepositType.None;
            }
            if (len != expectedLen) {
                return DepositType.None;
            }
        }
        {
            // read chain id separately and verify that contract that emitted event is relevant
            uint256 chainId;
            assembly {
                chainId := calldataload(ptr)
            }
            //  if (chainId != Utils.currentChain()) return DepositType.None;
            // All checks are passed after this point, no errors allowed and we can modify state
            state.chainId = chainId;
            ptr += 0x20;
            len -= 0x20;
        }

        {
            uint256 structOffset;
            assembly {
                // skip 6 fields: receiptHash, destinationContract, contractAddress, chainId, sender, receiver
                structOffset := add(state, 0xc0)
                calldatacopy(structOffset, ptr, len)
            }
        }
        state.destinationContract = destinationContract;
        state.contractAddress = contractAddress;
        state.sender = sender;
        state.receiver = receiver;
        return depositType;
    }
}
