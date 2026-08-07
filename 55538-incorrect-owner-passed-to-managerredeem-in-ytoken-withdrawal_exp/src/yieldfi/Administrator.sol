// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

import {IRole} from "./administrator/interface/IRole.sol";
import {IBlackList} from "./administrator/interface/IBlackList.sol";
import {IPausable} from "./administrator/interface/IPausable.sol";
import {Constants} from "./Constants.sol";

/// @notice Minimal faithful stand-in for YieldFi's `Administrator` permissioning
/// registry (the real one lived in the deleted repo). It implements exactly the
/// IRole / IBlackList / IPausable surface that the real `Access` base queries. It
/// is NOT the contract the finding is about; the vulnerable contract is `YToken`.
contract Administrator is IRole, IBlackList, IPausable {
    mapping(bytes32 => mapping(address => bool)) internal _roles;
    mapping(address => bool) internal _blacklisted;
    mapping(address => bool) internal _paused;

    constructor() {
        _roles[Constants.ADMIN_ROLE][msg.sender] = true;
    }

    // --- IRole ---
    function grantRoles(bytes32 _role, address[] calldata _accounts) external {
        for (uint256 i; i < _accounts.length; ++i) {
            _roles[_role][_accounts[i]] = true;
            emit RoleGranted(_role, msg.sender, _accounts[i]);
        }
    }

    function revokeRoles(bytes32 _role, address[] calldata _accounts) external {
        for (uint256 i; i < _accounts.length; ++i) {
            _roles[_role][_accounts[i]] = false;
            emit RoleRevoked(_role, msg.sender, _accounts[i]);
        }
    }

    function hasRole(bytes32 _role, address _account) external view returns (bool) {
        return _roles[_role][_account];
    }

    function hasRoles(bytes32[] calldata _role, address[] calldata _accounts) external view returns (bool[] memory out) {
        out = new bool[](_role.length);
        for (uint256 i; i < _role.length; ++i) out[i] = _roles[_role[i]][_accounts[i]];
    }

    // --- IBlackList ---
    function blackListUsers(address[] calldata _users) external {
        for (uint256 i; i < _users.length; ++i) _blacklisted[_users[i]] = true;
    }

    function removeBlackListUsers(address[] calldata _clearedUsers) external {
        for (uint256 i; i < _clearedUsers.length; ++i) _blacklisted[_clearedUsers[i]] = false;
    }

    function isBlackListed(address _user) external view returns (bool) {
        return _blacklisted[_user];
    }

    // --- IPausable ---
    function pause() external {}
    function unpause() external {}
    function pauseSC(address _sc) external { _paused[_sc] = true; }
    function unpauseSC(address _sc) external { _paused[_sc] = false; }
    function isPaused(address _sc) external view returns (bool) { return _paused[_sc]; }
}
