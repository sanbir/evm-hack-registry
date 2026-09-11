// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC20.sol";

import "../interfaces/IInceptionBridge.sol";

contract MultipleDepositor {
    IInceptionBridge internal _bridge;

    constructor(IInceptionBridge bridge) {
        _bridge = bridge;
    }

    function deposit(
        address fromToken,
        uint256 destinationChain,
        address receiver,
        uint256 amount,
        uint256 numOfDeposits
    ) external {
        IERC20(fromToken).transferFrom(
            msg.sender,
            address(this),
            numOfDeposits * amount
        );
        IERC20(fromToken).approve(address(_bridge), numOfDeposits * amount);
        for (uint256 i = 0; i < numOfDeposits; i++) {
            _bridge.deposit(fromToken, destinationChain, receiver, amount);
        }
    }
}
