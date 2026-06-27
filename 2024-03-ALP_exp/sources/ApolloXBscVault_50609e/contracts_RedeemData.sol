// SPDX-License-Identifier: MIT

import {ApolloXRedeemData} from "./vaults/apolloX/ApolloXRedeemData.sol";
struct RedeemData {
  uint256 amount;
  address receiver;
  ApolloXRedeemData apolloXRedeemData;
}
