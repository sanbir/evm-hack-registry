// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ISwapContract{
    function swap(address fromToken, address toToken, uint256 amount) external;
    function estimateSwapAmount(address fromToken, address toToken, uint256 amount) external view returns (uint256);
    function supportTokens() external view returns (address[] memory);
    function getUSDPrice(address tokenAddress) external view returns (uint256);
    function getSwapRate(address fromToken, address toToken) external view returns (uint256);
    function isInWhiteList(address _address) external view returns (bool);
}