// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Client} from "../libraries/Client.sol";

interface IRouterClient {
    function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        view
        returns (uint256);

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        returns (bytes32);
}
