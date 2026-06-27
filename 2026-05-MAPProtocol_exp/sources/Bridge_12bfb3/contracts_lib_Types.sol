// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// struct DepositOutEvent {
//     bytes token;
//     bytes from;
//     bytes32 orderId;
//     uint256 fromChain;
//     uint256 toChain;
//     bytes mosOrRelay;
//     bytes to;
//     uint256 amount;
// }

struct MessageOutEvent {
    bool relay;
    uint8 messageType;
    uint256 fromChain;
    uint256 toChain;
    bytes32 orderId;
    bytes mos;
    bytes token;
    bytes initiator;
    bytes from;
    bytes to;
    uint256 amount;
    uint256 gasLimit;
    bytes swapData;
}

struct MessageInEvent {
    uint8 messageType;
    uint256 fromChain;
    uint256 toChain;
    bytes32 orderId;
    address mos;
    address token;
    bytes from;
    bytes to;
    uint256 amount;
    uint256 gasLimit;
    bytes swapData;
}
