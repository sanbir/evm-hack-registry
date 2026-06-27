// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracleConnector {
    function getPriceInUsd(address token) external view returns (int256, uint8, uint256);
    function getSupportedTokens() external view returns (address[] memory);
    function isTokenSupported(address token) external view returns (bool);
}
