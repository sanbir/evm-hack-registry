// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface ITokenMessenger {
    event MessageReceived(bytes32 messageHash);
    event MessageSent(uint32 destinationChain, bytes32 messageHash, uint256 amount);

    function sendMessage(
        uint32 destinationChain,
        bytes32 destinationAddress,
        uint256 amount,
        uint256 normalizedAmount,
        bytes calldata message
    ) external payable;
    function isMessageReceived(bytes32 messageHash) external view returns (bool);
    function receivedTokenAmount(bytes32 messageHash) external view returns (uint256);
    function token() external view returns (address);
    function getTransactionFeeInNative(uint32 destinationChain) external view returns (uint256);
}
