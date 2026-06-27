// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITokenDistributor {

    function distributeA(uint256 amount) external;

    function distributeB(uint256 amount) external;

    function isWhitelist(address user) external view returns (bool);

    function distributeEarlyReward(uint256 gas) external;

    function distributeLpReward(
        address[] memory accounts,
        uint256[] memory amounts
    ) external;
}