// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address guy, uint256 wad) external returns (bool);
}