// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @notice Reconstructed interface of the unverified BatchCall at
///         0x044dc3e39c566a95011e272ec800dbd2cc9c057c (Ethereum).
/// @dev Runtime selectors (from bytecode):
///        - batch(address[],bytes[])  = 0xf38f59d7  (primary entrypoint)
///        - 0x4300081f (secondary)
///      There is NO msg.sender / owner / allowlist check on batch().
///      Any caller can supply target addresses and calldatas; BatchCall
///      merely loops and performs the external calls.
///
///      Combined with an EIP-7702-delegated admin whose BatchExecutor
///      authorizes this BatchCall as BATCHER, that means any EOA can
///      drive privileged actions in the admin's authority.

contract BatchCall {
    error LengthMismatch();
    error CallFailed(uint256 index, address target, bytes data);

    /// @notice Permissionless multi-call. No access control.
    function batch(address[] calldata targets, bytes[] calldata datas) external {
        // Line of the bug: no auth on msg.sender.
        if (targets.length != datas.length) revert LengthMismatch();
        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok, ) = targets[i].call(datas[i]);
            if (!ok) revert CallFailed(i, targets[i], datas[i]);
        }
    }
}
