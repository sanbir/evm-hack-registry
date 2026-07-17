// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.6;

struct AxelarChainInfo{
    string destinationChain;
    string destinationAddress;
    uint256 messageFee;
}

struct AxelarCapsule{
    AxelarChainInfo[] chains;
    uint256 totalMessageFees;
}