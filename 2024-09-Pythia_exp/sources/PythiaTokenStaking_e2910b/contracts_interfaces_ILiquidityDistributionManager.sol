// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ILiquidityDistributionManager {
    function distributor(uint256 _duration) external returns (uint256);
}
