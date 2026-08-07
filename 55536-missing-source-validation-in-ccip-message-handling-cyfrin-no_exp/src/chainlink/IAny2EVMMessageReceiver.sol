// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Client} from "./Client.sol";

// Real Chainlink CCIP IAny2EVMMessageReceiver. Vendored unmodified (import path localised).
interface IAny2EVMMessageReceiver {
  function ccipReceive(Client.Any2EVMMessage calldata message) external;
}
