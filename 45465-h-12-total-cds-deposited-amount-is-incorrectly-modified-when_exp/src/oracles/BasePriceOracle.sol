// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface BasePriceOracle {
  error Oracle_CollateralAddressesAndPriceFeedIdsMustBeSameLength();

  function price(address underlying) external view returns (uint128, uint128);
}