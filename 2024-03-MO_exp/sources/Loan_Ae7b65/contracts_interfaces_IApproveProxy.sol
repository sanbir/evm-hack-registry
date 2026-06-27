// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IApproveProxy {
    function claim(address token, address from, address to, uint256 amount) external;
}
