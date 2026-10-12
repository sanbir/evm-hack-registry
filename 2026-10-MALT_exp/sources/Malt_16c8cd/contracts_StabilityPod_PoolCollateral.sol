// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

struct CoreCollateral {
  uint256 total;
  uint256 rewardOverflow;
  uint256 liquidityExtension;
  uint256 swingTrader;
  uint256 swingTraderMalt;
  uint256 arbTokens;
}

struct PoolCollateral {
  address lpPool;
  uint256 total;
  uint256 rewardOverflow;
  uint256 liquidityExtension;
  uint256 swingTrader;
  uint256 swingTraderMalt;
  uint256 arbTokens;
}
