// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IRewardsDistributor {
    function claimRewards(uint8 subjectType, uint256 subjectId, uint256[] calldata epochNumbers) external;
}
