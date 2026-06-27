// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IERC20Receiver {
    function onTokenBridged(address from, uint256 amount) external returns (bool);
}
