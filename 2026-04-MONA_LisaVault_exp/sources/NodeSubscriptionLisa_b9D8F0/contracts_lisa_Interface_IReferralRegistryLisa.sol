// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IReferralRegistryLisa {
   
    function getReferrer(address user) external view returns (bool, address);

    function getDirectReferrals(address user) external view returns (address[] memory);

    function getDirectReferralCount(address user) external view returns (uint256);

    function getUpwardReferrers(address user, uint256 depth) external view returns (address[] memory);

    function bind(address ref, address referee) external;
    function isWhitelisted(address account) external view returns (bool);
}