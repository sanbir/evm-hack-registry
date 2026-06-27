// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBProjects} from "@bananapus/core-v5/src/interfaces/IJBProjects.sol";

interface IJBOwnable {
    event PermissionIdChanged(uint8 newId, address caller);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner, address caller);

    function PROJECTS() external view returns (IJBProjects);
    function jbOwner() external view returns (address owner, uint88 projectOwner, uint8 permissionId);
    function owner() external view returns (address);

    function renounceOwnership() external;
    function setPermissionId(uint8 permissionId) external;
    function transferOwnership(address newOwner) external;
    function transferOwnershipToProject(uint256 projectId) external;
}
