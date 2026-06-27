// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface ICITStaking {
    function redeemCalculator(address user) external view returns (uint256[2][2] memory);
    function removeStaking(address user, address token, uint8 rate, uint256 amount) external;
    function getFixedRate() external view returns (uint256);
    function getCITInUSDAllFixedRates(address user, uint256 amount) external view returns (uint256);
}