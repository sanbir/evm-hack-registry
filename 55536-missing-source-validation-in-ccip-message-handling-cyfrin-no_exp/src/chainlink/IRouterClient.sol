// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Client} from "./Client.sol";

// Real Chainlink CCIP IRouterClient. Vendored unmodified (import path localised).
interface IRouterClient {
  error UnsupportedDestinationChain(uint64 destChainSelector);
  error InsufficientFeeTokenAmount();
  error InvalidMsgValue();

  function isChainSupported(uint64 destChainSelector) external view returns (bool supported);

  function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message)
    external
    view
    returns (uint256 fee);

  function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
    external
    payable
    returns (bytes32);
}
