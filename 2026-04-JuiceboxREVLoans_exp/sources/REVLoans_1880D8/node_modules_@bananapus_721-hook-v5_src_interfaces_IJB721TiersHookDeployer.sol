// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJB721TiersHook} from "./IJB721TiersHook.sol";
import {JBDeploy721TiersHookConfig} from "../structs/JBDeploy721TiersHookConfig.sol";

interface IJB721TiersHookDeployer {
    event HookDeployed(uint256 indexed projectId, IJB721TiersHook hook, address caller);

    function deployHookFor(
        uint256 projectId,
        JBDeploy721TiersHookConfig memory deployTiersHookConfig,
        bytes32 salt
    )
        external
        returns (IJB721TiersHook hook);
}
