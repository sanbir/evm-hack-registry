// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import './IProtocolFees.sol';

interface IProtocolFeeRouter {
  function protocolFees() external view returns (IProtocolFees);
}
