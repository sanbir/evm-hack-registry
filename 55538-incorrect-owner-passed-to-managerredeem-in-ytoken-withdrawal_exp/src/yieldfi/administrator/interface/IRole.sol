// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

interface IRole {
    //functions
    function grantRoles(bytes32 _role, address[] calldata _accounts) external;
    function revokeRoles(bytes32 _role, address[] calldata _accounts) external;
    function hasRole(bytes32 _role, address _account) external view returns (bool);
    function hasRoles(bytes32[] calldata _role, address[] calldata _accounts) external view returns (bool[] memory);

    //events
    event RoleGranted(bytes32 indexed _role, address indexed _sender, address indexed _account);
    event RoleRevoked(bytes32 indexed _role, address indexed _sender, address indexed _account);
}
