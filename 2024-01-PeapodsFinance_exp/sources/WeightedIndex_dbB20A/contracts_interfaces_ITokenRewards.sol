// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface ITokenRewards {
  event AddShares(address indexed wallet, uint256 amount);

  event RemoveShares(address indexed wallet, uint256 amount);

  event ClaimReward(address indexed wallet);

  event DistributeReward(address indexed wallet, uint256 amount);

  event DepositRewards(address indexed wallet, uint256 amount);

  function totalShares() external view returns (uint256);

  function totalStakers() external view returns (uint256);

  function rewardsToken() external view returns (address);

  function trackingToken() external view returns (address);

  function depositFromDAI(uint256 amount) external;

  function depositRewards(uint256 amount) external;

  function claimReward(address wallet) external;

  function setShares(
    address wallet,
    uint256 amount,
    bool sharesRemoving
  ) external;
}
