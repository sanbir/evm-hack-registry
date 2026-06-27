// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

struct ApolloXRedeemData {
  address alpTokenOut;
  uint256 minOut;
  address tokenOut;
  bytes aggregatorData;
}
