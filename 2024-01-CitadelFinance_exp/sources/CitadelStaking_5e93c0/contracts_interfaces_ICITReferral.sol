// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface ICITReferral {
    function getUserFromCode(bytes32 code) external view returns (address);
    function getReferrals(address user) external view returns (address[] memory);
    function getTimeOfReferrals(address user) external view returns (uint256[] memory);
    function getReferrer(address user) external view returns (address);
    function rewardsPerReferral() external view returns (uint256);
}