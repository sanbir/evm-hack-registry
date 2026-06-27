//SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

interface IPriceGetter {
  function getPrice() external view returns (uint256 price);
}
