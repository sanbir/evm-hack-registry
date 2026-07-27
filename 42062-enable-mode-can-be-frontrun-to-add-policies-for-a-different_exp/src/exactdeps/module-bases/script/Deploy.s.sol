// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Script } from "forge-std/Script.sol";
import { MockValidator } from "src/mocks/MockValidator.sol";

/**
 * @title Deploy
 * @author @kopy-kat
 */
contract DeployScript is Script {
    function run() public {
        bytes32 salt = bytes32(uint256(1));

        vm.startBroadcast(vm.envUint("PK"));

        // Deploy account and factory
        new MockValidator{ salt: salt }();

        vm.stopBroadcast();
    }
}
