// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58098-h-01-accounts-not-properly-removed-from-roles-upon-revoking.sol";

contract AstrolabRoleRevokeTest is Test {
    function test_exploit_revokedAdminKeepsRoleAndDrains() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.stillHasRole(), "revoked admin still has role");
        assertEq(e.stolen(), 1000 ether, "treasury drained by revoked admin");
        assertEq(e.token().balanceOf(address(e.vault())), 0, "vault empty");
        assertTrue(
            e.vault().hasRole(e.vault().DEFAULT_ADMIN_ROLE(), address(e.oldAdmin())),
            "hasRole still true"
        );
    }

    function test_control_clearIndexRemovesRole() public {
        // Control: if index is cleared, hasRole is false after remove.
        MockToken token = new MockToken();
        FixedVault v = new FixedVault(token, address(this));
        address other = address(0xA11CE);
        v.grantRole(v.DEFAULT_ADMIN_ROLE(), other);
        assertTrue(v.hasRole(v.DEFAULT_ADMIN_ROLE(), address(this)));
        v.revokeRole(v.DEFAULT_ADMIN_ROLE(), address(this));
        assertFalse(v.hasRole(v.DEFAULT_ADMIN_ROLE(), address(this)), "properly revoked");
    }
}

/// @dev Fixed set that clears index on remove.
library FixedSet {
    struct Set {
        bytes32[] data;
        mapping(bytes32 => uint32) index;
    }

    function add(Set storage q, bytes32 o) internal {
        if (q.index[o] != 0) return;
        q.data.push(o);
        q.index[o] = uint32(q.data.length);
    }

    function remove(Set storage q, bytes32 o) internal {
        uint32 i = q.index[o];
        q.index[o] = 0; // FIX
        require(i > 0, "Element not found");
        require(i - 1 < q.data.length, "oob");
        uint256 idx = i - 1;
        if (idx < q.data.length - 1) {
            bytes32 last = q.data[q.data.length - 1];
            q.data[idx] = last;
            q.index[last] = uint32(idx + 1);
        }
        q.data.pop();
    }

    function has(Set storage q, bytes32 o) internal view returns (bool) {
        return q.index[o] > 0 && q.index[o] <= q.data.length;
    }
}

contract FixedVault {
    using FixedSet for FixedSet.Set;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    mapping(bytes32 => FixedSet.Set) private _roles;
    MockToken public immutable token;

    constructor(MockToken _token, address initialAdmin) {
        token = _token;
        _roles[DEFAULT_ADMIN_ROLE].add(bytes32(uint256(uint160(initialAdmin))));
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role].has(bytes32(uint256(uint160(account))));
    }

    function grantRole(bytes32 role, address account) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "not admin");
        _roles[role].add(bytes32(uint256(uint160(account))));
    }

    function revokeRole(bytes32 role, address account) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "not admin");
        if (hasRole(role, account)) {
            _roles[role].remove(bytes32(uint256(uint160(account))));
        }
    }
}
