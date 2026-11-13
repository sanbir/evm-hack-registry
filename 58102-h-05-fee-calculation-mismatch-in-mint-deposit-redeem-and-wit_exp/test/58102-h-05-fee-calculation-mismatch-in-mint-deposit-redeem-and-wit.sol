// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Astrolab As4626 — deposit and redeem take the fee off the gross amount
    (Pashov, Astrolab, 2024-01, H-05).
    SYNTHETIC, cheatcode-free. Price is 1:1, fee is 10%, as in the report.

    mint(100) charges addBp = 110. deposit(110) uses subBp and mints 99 shares
    instead of 100. redeem(110) pays 99 assets instead of 100.
    Fair fee is amount * 10000 / 11000. */

contract Asset {
    string public constant name = "AST";
    string public constant symbol = "AST";
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
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract As4626 {
    uint256 public constant BP = 10_000;
    uint256 public constant FEE = 1_000;
    Asset public asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(Asset asset_) {
        asset = asset_;
    }

    function convertToAssets(uint256 shares) public pure returns (uint256) {
        return shares;
    }

    function convertToShares(uint256 assets) public pure returns (uint256) {
        return assets;
    }

    function addBp(uint256 amount) public pure returns (uint256) {
        return amount * (BP + FEE) / BP;
    }

    function subBp(uint256 amount) public pure returns (uint256) {
        return amount * (BP - FEE) / BP;
    }

    function previewMint(uint256 shares) public pure returns (uint256) {
        return addBp(convertToAssets(shares));
    }

    function previewDeposit(uint256 amount) public pure returns (uint256) {
        uint256 shares = convertToShares(amount);
        return shares * (BP - FEE) / BP;
    }

    function previewRedeem(uint256 shares) public pure returns (uint256) {
        uint256 assets = convertToAssets(shares);
        // @> VULN: subBp of the gross amount, not amount * base / (base + fee)
        return assets * (BP - FEE) / BP;
    }

    function previewWithdraw(uint256 assets) public pure returns (uint256) {
        return addBp(convertToShares(assets));
    }

    function fairShares(uint256 amount) public pure returns (uint256) {
        return amount * BP / (BP + FEE);
    }

    function fairAssets(uint256 shares) public pure returns (uint256) {
        return shares * BP / (BP + FEE);
    }

    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        shares = previewDeposit(amount);
        asset.transferFrom(msg.sender, address(this), amount);
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function redeem(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = previewRedeem(shares);
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        asset.transfer(receiver, assets);
    }

    function seed(address to, uint256 shares, uint256 assets) external {
        asset.transferFrom(msg.sender, address(this), assets);
        balanceOf[to] += shares;
        totalSupply += shares;
    }
}

contract As4626Fixed {
    uint256 public constant BP = 10_000;
    uint256 public constant FEE = 1_000;
    Asset public asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(Asset asset_) {
        asset = asset_;
    }

    function previewDeposit(uint256 amount) public pure returns (uint256) {
        return amount * BP / (BP + FEE);
    }

    function previewRedeem(uint256 shares) public pure returns (uint256) {
        return shares * BP / (BP + FEE);
    }

    function previewMint(uint256 shares) public pure returns (uint256) {
        return shares * (BP + FEE) / BP;
    }

    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        shares = previewDeposit(amount);
        asset.transferFrom(msg.sender, address(this), amount);
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function redeem(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = previewRedeem(shares);
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        asset.transfer(receiver, assets);
    }

    function seed(address to, uint256 shares, uint256 assets) external {
        asset.transferFrom(msg.sender, address(this), assets);
        balanceOf[to] += shares;
        totalSupply += shares;
    }
}

contract Depositor {
    function deposit(Asset asset, As4626 vault, uint256 amount) external returns (uint256) {
        asset.approve(address(vault), amount);
        return vault.deposit(amount, address(this));
    }
}

contract Exploit {
    uint256 public constant GROSS = 110 ether;
    uint256 public constant BUGGY = 99 ether;
    uint256 public constant FAIR = 100 ether;

    Asset public asset; // nonce 1
    As4626 public vault; // nonce 2
    Depositor public depositor; // nonce 3

    uint256 public mintCost;
    uint256 public depositedShares;
    uint256 public fairDeposit;
    uint256 public redeemed;
    uint256 public fairRedeem;

    constructor() {
        asset = new Asset();
        vault = new As4626(asset);
        depositor = new Depositor();
        asset.mint(address(depositor), GROSS);
        asset.mint(address(this), GROSS);
        asset.approve(address(vault), GROSS);
        vault.seed(address(this), GROSS, GROSS);
    }

    function run() external {
        mintCost = vault.previewMint(FAIR);
        fairDeposit = vault.fairShares(GROSS);
        depositedShares = depositor.deposit(asset, vault, GROSS);
        fairRedeem = vault.fairAssets(GROSS);
        redeemed = vault.redeem(GROSS, address(this));
        require(mintCost == 110 ether, "mint charges 110");
        require(depositedShares == BUGGY, "deposit mints 99");
        require(fairDeposit == FAIR, "fair deposit is 100");
        require(redeemed == BUGGY, "redeem pays 99");
        require(fairRedeem == FAIR, "fair redeem is 100");
        require(FAIR - redeemed == 1 ether, "redeem overcharges 1");
        require(fairDeposit - depositedShares == 1 ether, "deposit overcharges 1");
    }
}
