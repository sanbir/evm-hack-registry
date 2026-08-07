// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

import {CCIPReceiver} from "../chainlink/CCIPReceiver.sol";
import {Client} from "../chainlink/Client.sol";
import {Codec, BridgeSendPayload} from "./Codec.sol";

interface IBridgeToken {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice YieldFi's Chainlink-CCIP bridge receiver, as audited at the deleted
/// `YieldFiLabs/contracts` commit 40caad6c, `contracts/bridge/ccip/BridgeCCIP.sol`.
///
/// The `_ccipReceive` prefix (decode / dedup / amount check) is reproduced
/// VERBATIM from the Cyfrin YieldFi v2.0 report (finding: "Missing source
/// validation in CCIP message handling"). The report elides the token action
/// as "..."; per its own text the action is to "trigger the minting or
/// unlocking of arbitrary tokens" for `payload.to`. Here we implement the L1
/// unlock: the bridge releases `payload.amount` of locked yToken to
/// `payload.to`. `Codec` is the real YieldFi library; `CCIPReceiver` is the
/// real Chainlink base.
///
/// VULNERABILITY (55536): `_ccipReceive` reads `payload` and acts on it WITHOUT
/// validating `any2EvmMessage.sourceChainSelector` or the decoded
/// `any2EvmMessage.sender`. Chainlink CCIP will deliver a message sent from ANY
/// source chain / ANY sender contract (the OffRamp only guarantees msg.sender ==
/// router, which `CCIPReceiver.onlyRouter` checks). An attacker therefore
/// deploys a contract on any CCIP-connected chain, sends a crafted payload, and
/// the bridge unlocks (L1) or mints (L2) arbitrary tokens to an attacker address.
contract BridgeCCIP is CCIPReceiver {
    bool public isL1;
    address public localYToken; // the yToken this bridge unlocks (L1) or mints (L2)
    mapping(bytes32 => bool) public processedMessages;

    event Unlocked(address indexed to, uint256 amount);

    constructor(address _router, bool _isL1, address _localYToken) CCIPReceiver(_router) {
        isL1 = _isL1;
        localYToken = _localYToken;
    }

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        // --- verbatim prefix from the audit report (BridgeCCIP.sol#L160-L181) ---
        bytes memory message = abi.decode(any2EvmMessage.data, (bytes));
        BridgeSendPayload memory payload = Codec.decodeBridgeSendPayload(message);
        bytes32 _hash = keccak256(abi.encode(message, any2EvmMessage.messageId));
        require(!processedMessages[_hash], "processed");

        processedMessages[_hash] = true;

        require(payload.amount > 0, "!amount");
        // @audit-issue NO validation of any2EvmMessage.sourceChainSelector / sender
        // ----------------------------------------------------------------------

        // audited "..." action: unlock (L1) / mint (L2) to payload.to.
        IBridgeToken(localYToken).transfer(payload.to, payload.amount);
        emit Unlocked(payload.to, payload.amount);
    }
}

/// @notice The SAME contract with the report's Recommended Mitigation applied:
/// a `allowedPeers[sourceChainSelector][sender]` gate. Used as the negative
/// control — the identical untrusted delivery reverts here.
contract BridgeCCIPFixed is CCIPReceiver {
    bool public isL1;
    address public localYToken;
    mapping(bytes32 => bool) public processedMessages;
    mapping(uint64 => mapping(address => bool)) public allowedPeers;

    constructor(address _router, bool _isL1, address _localYToken) CCIPReceiver(_router) {
        isL1 = _isL1;
        localYToken = _localYToken;
    }

    function setAllowedPeer(uint64 sourceChain, address peer, bool ok) external {
        allowedPeers[sourceChain][peer] = ok;
    }

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        // Recommended Mitigation (report): only accept trusted source peers.
        address sender = abi.decode(any2EvmMessage.sender, (address));
        require(allowedPeers[any2EvmMessage.sourceChainSelector][sender], "allowed");

        bytes memory message = abi.decode(any2EvmMessage.data, (bytes));
        BridgeSendPayload memory payload = Codec.decodeBridgeSendPayload(message);
        bytes32 _hash = keccak256(abi.encode(message, any2EvmMessage.messageId));
        require(!processedMessages[_hash], "processed");
        processedMessages[_hash] = true;
        require(payload.amount > 0, "!amount");

        IBridgeToken(localYToken).transfer(payload.to, payload.amount);
    }
}
