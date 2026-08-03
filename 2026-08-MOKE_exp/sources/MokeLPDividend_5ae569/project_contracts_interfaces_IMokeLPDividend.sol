// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IMokeLPDividend {
    function syncUserLP(address user) external;
    function distributeDividend() external payable;
    function claimDividend() external;
    function getPendingDividend(address user) external view returns (uint256);
}
