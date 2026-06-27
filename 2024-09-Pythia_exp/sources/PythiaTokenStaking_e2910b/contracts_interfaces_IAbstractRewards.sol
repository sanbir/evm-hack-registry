// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IAbstractRewards {
    function getRedeemablePayouts(address _account) external view returns (uint256);
    function getRedeemedPayouts(address _account) external view returns (uint256);
    function getCumulativePayouts(address _account) external view returns (uint256);

    event RewardsDistributed(address indexed recipient, uint256 amount);
    event RewardsWithdrawn(address indexed recipient, uint256 amount);
}
