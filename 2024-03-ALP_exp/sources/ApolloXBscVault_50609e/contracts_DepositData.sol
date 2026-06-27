// SPDX-License-Identifier: MIT

import {ApolloXDepositData} from "./vaults/apolloX/ApolloXDepositData.sol";
struct DepositData {
  uint256 amount;
  address receiver;
  address tokenIn;
  address tokenInAfterSwap;
  bytes aggregatorData;
  ApolloXDepositData apolloXDepositData;
}
