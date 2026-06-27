// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/**
 * @title IPancakeFactory
 * @notice Minimal PancakeSwap V2 Factory interface used by WHALE
 */
interface IPancakeFactory {
    function feeTo() external view returns (address);
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address);
}
