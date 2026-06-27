// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBProjects} from "@bananapus/core-v5/src/interfaces/IJBProjects.sol";
import {JBSuckerDeployerConfig} from "../structs/JBSuckerDeployerConfig.sol";
import {JBSuckersPair} from "../structs/JBSuckersPair.sol";

interface IJBSuckerRegistry {
    event SuckerDeployedFor(uint256 projectId, address sucker, JBSuckerDeployerConfig configuration, address caller);
    event SuckerDeployerAllowed(address deployer, address caller);
    event SuckerDeployerRemoved(address deployer, address caller);
    event SuckerDeprecated(uint256 projectId, address sucker, address caller);

    function DIRECTORY() external view returns (IJBDirectory);
    function PROJECTS() external view returns (IJBProjects);

    function isSuckerOf(uint256 projectId, address addr) external view returns (bool);
    function suckerDeployerIsAllowed(address deployer) external view returns (bool);
    function suckerPairsOf(uint256 projectId) external view returns (JBSuckersPair[] memory pairs);
    function suckersOf(uint256 projectId) external view returns (address[] memory);

    function allowSuckerDeployer(address deployer) external;
    function allowSuckerDeployers(address[] calldata deployers) external;
    function deploySuckersFor(
        uint256 projectId,
        bytes32 salt,
        JBSuckerDeployerConfig[] memory configurations
    )
        external
        returns (address[] memory suckers);
    function removeDeprecatedSucker(uint256 projectId, address sucker) external;
    function removeSuckerDeployer(address deployer) external;
}
