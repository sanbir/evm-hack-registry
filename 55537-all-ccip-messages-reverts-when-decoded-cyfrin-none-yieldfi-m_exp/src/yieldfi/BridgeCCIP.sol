// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

import {CCIPReceiver} from "../chainlink/CCIPReceiver.sol";
import {Client} from "../chainlink/Client.sol";
import {IRouterClient} from "../chainlink/IRouterClient.sol";
import {Codec, BridgeSendPayload} from "./Codec.sol";
import {Constants} from "./Constants.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

/// @notice YieldFi's Chainlink-CCIP bridge receiver, as audited at the deleted
/// `YieldFiLabs/contracts` commit 40caad6c, `contracts/bridge/ccip/BridgeCCIP.sol`.
///
/// The `send` and `_ccipReceive` bodies below are reproduced VERBATIM from the
/// Cyfrin YieldFi v2.0 report (the audited repo was deleted; the report is the
/// auditor's own copy of the audited source). Admin/Ownable plumbing that does
/// not affect the decode path is elided. `Codec` is the real YieldFi library.
///
/// Finding 55537 ("All CCIP messages reverts when decoded"): `send` encodes the
/// payload with the *uint64* destination chain selector as its first field, but
/// `_ccipReceive` -> `Codec.decodeBridgeSendPayload` reads it back into a
/// `uint32 dstId`. Because every real Chainlink selector exceeds `uint32.max`,
/// `abi.decode` reverts on that first field, so EVERY inbound CCIP message
/// reverts during decoding. The contract is not upgradeable and CCIP messages
/// cannot be retried -> permanent cross-chain liveness break / stuck funds.
contract BridgeCCIP is CCIPReceiver {
    // storage mirrors the audited contract (report: `address public router;`,
    // `isL1`, `tokens`, `lockboxes`)
    address public router;
    bool public isL1;
    mapping(bytes32 => bool) public processedMessages;
    mapping(address => address) public lockboxes;
    mapping(address => mapping(uint64 => address)) public tokens;

    constructor(address _router, bool _isL1) CCIPReceiver(_router) {
        router = _router;
        isL1 = _isL1;
    }

    function setToken(address _yToken, uint64 _dstChain, address _remoteToken) external {
        tokens[_yToken][_dstChain] = _remoteToken;
    }

    function setLockbox(address _yToken, address _lockbox) external {
        lockboxes[_yToken] = _lockbox;
    }

    /// @dev VERBATIM from the Cyfrin report (BridgeCCIP.sol#L117-L158). This is
    /// the source chain's send path: note `_dstChain` (uint64) is packed as the
    /// first field of `_encodedMessage`.
    function send(address _yToken, uint64 _dstChain, address _to, uint256 _amount, address _receiver)
        external
        payable
    {
        require(_amount > 0, "!amount");
        require(lockboxes[_yToken] != address(0), "!token !lockbox");
        require(IERC20(_yToken).balanceOf(msg.sender) >= _amount, "!balance");
        require(_to != address(0), "!receiver");
        require(tokens[_yToken][_dstChain] != address(0), "!destination");

        bytes memory _encodedMessage =
            abi.encode(_dstChain, _to, tokens[_yToken][_dstChain], _amount, Constants.BRIDGE_SEND_HASH);

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: abi.encode(_encodedMessage),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true})),
            feeToken: address(0)
        });

        IRouterClient(router).ccipSend{value: msg.value}(_dstChain, evm2AnyMessage);
    }

    /// @dev VERBATIM prefix from the Cyfrin report (BridgeCCIP.sol#L160-L181).
    /// The token mint/unlock action the audit elided as "..." would run after
    /// the checks below, but is NEVER REACHED: `decodeBridgeSendPayload` reverts
    /// on the very first statement for any real (uint64) chain selector.
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        bytes memory message = abi.decode(any2EvmMessage.data, (bytes)); // abi-decoding of the sent text
        BridgeSendPayload memory payload = Codec.decodeBridgeSendPayload(message); // @audit reverts here (55537)
        bytes32 _hash = keccak256(abi.encode(message, any2EvmMessage.messageId));
        require(!processedMessages[_hash], "processed");

        processedMessages[_hash] = true;

        require(payload.amount > 0, "!amount");

        // ... (audited: mint on L2 / unlock on L1 to payload.to — unreachable)
    }
}
