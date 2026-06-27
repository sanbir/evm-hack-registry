// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBTokens} from "@bananapus/core-v5/src/interfaces/IJBTokens.sol";

import {IJBSucker} from "./IJBSucker.sol";

interface IJBSuckerDeployer {
    error JBSuckerDeployer_AlreadyConfigured();
    error JBSuckerDeployer_DeployerIsNotConfigured();
    error JBSuckerDeployer_InvalidLayerSpecificConfiguration();
    error JBSuckerDeployer_LayerSpecificNotConfigured();
    error JBSuckerDeployer_Unauthorized(address caller, address expected);
    error JBSuckerDeployer_ZeroConfiguratorAddress();

    function DIRECTORY() external view returns (IJBDirectory);
    function TOKENS() external view returns (IJBTokens);
    function LAYER_SPECIFIC_CONFIGURATOR() external view returns (address);

    function isSucker(address sucker) external view returns (bool);

    function createForSender(uint256 localProjectId, bytes32 salt) external returns (IJBSucker sucker);
}
