// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function feeTo() external view returns (address);
}
