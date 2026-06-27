// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ISwapOutLimit {
    function checkLimit(uint256 amount, uint256 tochain, address token) external;
}
