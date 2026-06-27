// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IProtocolFees {
  event SetYieldAdmin(uint256 newFee);
  event SetYieldBurn(uint256 newFee);

  function DEN() external view returns (uint256);

  function yieldAdmin() external view returns (uint256);

  function yieldBurn() external view returns (uint256);
}
