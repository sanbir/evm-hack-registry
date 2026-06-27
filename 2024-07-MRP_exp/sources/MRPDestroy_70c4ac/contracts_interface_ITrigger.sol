// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface ITrigger {
    function handle(address from, uint256 amount) external returns (bool);
}
