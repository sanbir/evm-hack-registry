  // SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
interface IAAVERewards{
  function claimAllRewards(address[] calldata assets, address to) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}