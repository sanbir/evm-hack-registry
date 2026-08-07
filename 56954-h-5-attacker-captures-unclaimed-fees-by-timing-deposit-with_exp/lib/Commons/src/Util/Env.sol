// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.12; // For string concat

import {VmSafe} from "forge-std/Vm.sol";

contract EnvLoader {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));
    string private _loadedJson;

    error EnvNotLoaded();

    /* Json Internals */
    function loadJsonFile() internal {
        string memory pathToAddrs = vm.envString("DEPLOYED_ADDRS_PATH");
        string memory projectRoot = string.concat(vm.projectRoot(), "/");
        string memory jsonPath = string.concat(projectRoot, pathToAddrs);
        _loadedJson = vm.readFile(jsonPath);
    }

    // How child classes interact with the fork addresses
    function getAddr(string memory key) internal view returns (address) {
        if (bytes(_loadedJson).length == 0)
            revert EnvNotLoaded();
        return vm.parseJsonAddress(_loadedJson, string.concat(".", key));
    }
}
