// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface IStakingPoolToken {
  event Stake(address indexed executor, address indexed user, uint256 amount);

  event Unstake(address indexed user, uint256 amount);

  function indexFund() external view returns (address);

  function stakingToken() external view returns (address);

  function poolRewards() external view returns (address);

  function stakeUserRestriction() external view returns (address);

  function stake(address user, uint256 amount) external;

  function unstake(uint256 amount) external;
}
