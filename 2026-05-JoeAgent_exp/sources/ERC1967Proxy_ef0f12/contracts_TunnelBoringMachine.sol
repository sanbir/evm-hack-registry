// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Tunnel/TunnelContract.sol";

contract TunnelBoringMachine {
    uint64 public immutable VERSION;

    constructor(uint64 version) {
        VERSION = version;
    }

    function openNewTunnel(address hubAddress, string memory tunnelName, bool isLockMode) external returns (address tunnelAddress) {
        bytes memory bytecode = abi.encodePacked(type(TunnelContract).creationCode, abi.encode(VERSION, hubAddress, tunnelName, isLockMode));
        bytes32 salt = bytes32(0);
        assembly {
            tunnelAddress := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(tunnelAddress != address(0), "TunnelContract failed to deploy");
    }
}
