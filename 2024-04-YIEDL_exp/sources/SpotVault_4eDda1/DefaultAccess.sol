// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "AccessControlEnumerable.sol";

abstract contract DefaultAccess is AccessControlEnumerable {
    bytes32 public constant MASTER = keccak256('MASTER');
    bytes32 public constant OPERATOR = keccak256('OPERATOR');

    function _initDefaultAccess(address admin_) internal {
        _grantRole(MASTER, admin_);
        _setRoleAdmin(MASTER, MASTER);
        _grantRole(OPERATOR, admin_);
        _setRoleAdmin(OPERATOR, MASTER);
    }
}
