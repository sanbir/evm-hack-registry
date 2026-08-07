// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

import {Common} from "./Common.sol";
import {Constants} from "./Constants.sol";

// Real YieldFi source, byte-identical to
// github.com/YieldFiLabs/smart-contracts/contracts/libs/Codec.sol EXCEPT that
// `decodeBridgeSendPayload` takes `bytes memory` (the audited BridgeCCIP at the
// deleted `YieldFiLabs/contracts@40caad6c` calls it with the `bytes memory`
// value produced by `abi.decode(any2EvmMessage.data,(bytes))`). The vulnerable
// line -- `abi.decode(_data,(uint32,address,address,uint256,bytes32))` reading
// the destination CCIP chain selector into a `uint32 dstId` -- is unchanged and
// is exactly the code the Cyfrin report (finding: "All CCIP messages reverts
// when decoded") quotes from Codec.sol#L22-L51.
struct RewardPayload {
    address receiver;
    uint256 amount;
    uint256 epoch;
    uint256 rewardType;
}

struct BridgeSendPayload {
    uint32 dstId; // @audit BUG: Chainlink chain selectors are uint64 and all exceed uint32.max
    address to;
    address token;
    uint256 amount;
    bytes32 trxnType;
}

error WrongDataLength();
error WrongAddressEncoding();
error WrongData();

library Codec {
    uint256 internal constant DATA_LENGTH = 32 * 5;

    function decodeReward(bytes calldata _data) internal view returns (RewardPayload memory) {
        if (_data.length != DATA_LENGTH) {
            revert WrongDataLength();
        }

        (address receiver, uint256 amount, uint256 epoch, uint256 rewardType, bytes32 trxnType) =
            abi.decode(_data, (address, uint256, uint256, uint256, bytes32));

        if (trxnType != Constants.REWARD_HASH) {
            revert WrongData();
        }

        if (receiver == address(0) || !Common.isContract(receiver)) {
            revert WrongAddressEncoding();
        }

        if (amount == 0 || epoch < 1 || rewardType >= 2) {
            revert WrongData();
        }

        return RewardPayload(receiver, amount, epoch, rewardType);
    }

    function decodeBridgeSendPayload(bytes memory _data) internal view returns (BridgeSendPayload memory) {
        if (_data.length != DATA_LENGTH) {
            revert WrongDataLength();
        }

        // @audit BUG (finding 55537): the source-chain `send` encodes the payload
        // with the *uint64* destination CCIP selector as the first field, but it
        // is decoded here into a `uint32 dstId`. abi.decode validates the high
        // bits of the 32-byte word and REVERTS because a uint64 selector (e.g.
        // Ethereum = 5009297550715157269) has bits set above bit 32. Every CCIP
        // message therefore reverts at this line, before any of the checks below.
        (uint32 dstId, address to, address token, uint256 amount, bytes32 trxnType) =
            abi.decode(_data, (uint32, address, address, uint256, bytes32));

        if (trxnType != Constants.BRIDGE_SEND_HASH) {
            revert WrongData();
        }
        if (dstId == 0) {
            revert WrongData();
        }
        if (to == address(0)) {
            revert WrongAddressEncoding();
        }
        if (token == address(0) || !Common.isContract(token)) {
            revert WrongAddressEncoding();
        }
        if (amount == 0) {
            revert WrongData();
        }

        return BridgeSendPayload(dstId, to, token, amount, trxnType);
    }
}
