// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "moolah/interfaces/IMoolah.sol";

interface IProvider {
  function liquidate(Id id, address borrower) external;

  function TOKEN() external view returns (address);
}

interface ISmartProvider is IProvider {
  function dexLP() external view returns (address);

  function token(uint256 id) external view returns (address);

  function redeemLpCollateral(
    uint256 lpAmount,
    uint256 minToken0Out,
    uint256 minToken1Out
  ) external returns (uint256 token0Out, uint256 token1Out);
}
