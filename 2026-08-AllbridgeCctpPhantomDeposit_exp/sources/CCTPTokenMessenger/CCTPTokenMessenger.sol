// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ITokenMessenger} from "./interfaces/ITokenMessenger.sol";
import {ChainGasUsage} from "./ChainGasUsage.sol";

interface ICCTPTokenMessenger {
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;

    function localMessageTransmitter() external view returns (address);
}

interface IMessageTransmitter {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

contract CCTPTokenMessenger is ITokenMessenger, ChainGasUsage {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_FEE_SHARE_P = 1e9;

    address public immutable TOKEN;
    address public immutable TOKEN_MESSENGER;
    address public immutable MESSAGE_TRANSMITTER;
    address public immutable ROUTER;
    uint32 public minFinalityThreshold = 1000;
    uint256 public maxFeeShare = 100000;

    mapping(uint32 chainId => uint32 domainPlusOne) public domainMapping;
    mapping(uint32 chainId => bytes32 remoteRouter) public remoteRouters;
    mapping(uint32 chainId => bytes32 remoteTokenMessenger) public remoteTokenMessengers;
    mapping(bytes32 messageHash => uint256 receivedAmount) public receivedMessages;

    mapping(uint32 domain => uint32 chainId) public domainToChainId;

    address public constant ETH_MARKER = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    constructor(address _router, address _token, address _tokenMessenger) Ownable(msg.sender) {
        ROUTER = _router;
        TOKEN = _token;
        TOKEN_MESSENGER = _tokenMessenger;
        MESSAGE_TRANSMITTER = ICCTPTokenMessenger(_tokenMessenger).localMessageTransmitter();
    }

    function setDomainMapping(uint32 chain, uint32 domain) external onlyOwner {
        domainMapping[chain] = domain + 1;
        domainToChainId[domain] = chain;
    }

    function setRemoteRouter(uint32 chain, bytes32 remoteRouter) external onlyOwner {
        remoteRouters[chain] = remoteRouter;
    }

    function setRemoteTokenMessenger(uint32 chain, bytes32 remoteTokenMessenger) external onlyOwner {
        remoteTokenMessengers[chain] = remoteTokenMessenger;
    }

    function setMinFinalityThreshold(uint32 _minFinalityThreshold) external onlyOwner {
        minFinalityThreshold = _minFinalityThreshold;
    }

    function setMaxFeeShare(uint256 _maxFeeShare) external onlyOwner {
        maxFeeShare = _maxFeeShare;
    }

    function sendMessage(
        uint32 destinationChain,
        bytes32,
        /*destinationAddress*/
        uint256 amount,
        uint256,
        /*normalizedAmount*/
        bytes calldata message
    )
        external
        payable
        override
    {
        require(msg.sender == ROUTER, "CCTPTokenMessenger: only router");
        uint256 messengerFee = getTransactionFeeInNative(destinationChain);
        require(msg.value >= messengerFee, "Insufficient messenger fee");

        uint32 domainPlusOne = domainMapping[destinationChain];
        require(domainPlusOne != 0, "Domain not registered");
        uint32 domain = domainPlusOne - 1;

        bytes32 remoteRouter = remoteRouters[destinationChain];
        bytes32 remoteTokenMessenger = remoteTokenMessengers[destinationChain];

        require(remoteRouter != bytes32(0), "Remote router not set");
        require(remoteTokenMessenger != bytes32(0), "Remote tokenMessenger not set");

        // 1. Transfer tokens from Router to here
        IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), amount);

        // 2. Approve TokenMessenger
        IERC20(TOKEN).forceApprove(TOKEN_MESSENGER, amount);
        uint256 maxFee = (amount * maxFeeShare) / MAX_FEE_SHARE_P + 1;

        // 3. Call TokenMessenger.depositForBurnWithHook
        // message contains the messageHash
        ICCTPTokenMessenger(TOKEN_MESSENGER)
            .depositForBurnWithHook(
                amount, domain, remoteRouter, TOKEN, remoteTokenMessenger, maxFee, minFinalityThreshold, message
            );

        bytes32 messageHash = abi.decode(message, (bytes32));
        emit MessageSent(destinationChain, messageHash, amount);
    }

    function isMessageReceived(bytes32 messageHash) external view override returns (bool) {
        return receivedMessages[messageHash] > 0;
    }

    function receivedTokenAmount(bytes32 messageHash) external view override returns (uint256) {
        return receivedMessages[messageHash];
    }

    function token() external view override returns (address) {
        return TOKEN;
    }

    function getTransactionFeeInNative(uint32 destinationChain)
        public
        view
        override(ChainGasUsage, ITokenMessenger)
        returns (uint256)
    {
        return super.getTransactionFeeInNative(destinationChain);
    }

    // Function to be called by CCTP message relayer
    // It relays the message to MessageTransmitter and marks the messageHash as received
    function receiveCctpMessage(bytes calldata message, bytes calldata attestation) external {
        // CCTP v2 Message Layout:
        // Header:
        // sourceDomain: bytes 4..8
        // destinationCaller: bytes 108..140
        // Body (BurnMessageV2) starts at 148:
        // messageSender (source sender): bytes 100..132 in body -> 248..280 in message
        // hookData: bytes 228.. in body -> 376.. in message

        require(message.length >= 408, "Message too short");

        uint32 sourceDomain = uint32(bytes4(message[4:8]));
        bytes32 destCaller = bytes32(message[108:140]);
        // Body (BurnMessageV2) starts at offset 148
        // amount: bytes 68..100 in body -> 216..248 in message
        uint256 amount = uint256(bytes32(message[216:248]));
        // feeExecuted: bytes 164..196 in body -> 312..344 in message
        uint256 feeExecuted = uint256(bytes32(message[312:344]));
        // sourceSender: bytes 100..132 in body -> 248..280 in message
        bytes32 sourceSender = bytes32(message[248:280]);
        // hookData: bytes 228.. in body -> 376.. in message
        bytes32 messageHash = bytes32(message[376:408]);

        require(destCaller == bytes32(uint256(uint160(address(this)))), "Invalid destination caller");

        uint32 sourceChainId = domainToChainId[sourceDomain];
        require(sourceChainId != 0, "Unknown source domain");

        require(sourceSender == remoteTokenMessengers[sourceChainId], "Invalid remote sender");

        // Relay to MessageTransmitter
        bool success = IMessageTransmitter(MESSAGE_TRANSMITTER).receiveMessage(message, attestation);
        require(success, "CCTP receiveMessage failed");

        uint256 receivedAmount = amount - feeExecuted;

        receivedMessages[messageHash] = receivedAmount;
        emit MessageReceived(messageHash);
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
            uint256 payout = amount == 0 ? address(this).balance : amount;
            (bool success,) = to.call{value: payout}("");
            require(success, "Native transfer failed");
    }
}
