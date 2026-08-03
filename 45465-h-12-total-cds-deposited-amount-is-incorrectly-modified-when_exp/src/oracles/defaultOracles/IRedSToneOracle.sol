// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IRedstoneOracle {
  function priceOf(address asset) external view returns (uint256);

  function priceOfETH() external view returns (uint256);

  function getDataFeedIdForAsset(address asset) external view returns (bytes32);

  function getDataFeedIds() external view returns (bytes32[] memory dataFeedIds);
}