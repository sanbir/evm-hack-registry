// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface LinkTokenInterface {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}
