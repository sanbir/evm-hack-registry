// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface ITreasury {
    function distributeRedeem(address token, uint256 amount, address user) external;
}

