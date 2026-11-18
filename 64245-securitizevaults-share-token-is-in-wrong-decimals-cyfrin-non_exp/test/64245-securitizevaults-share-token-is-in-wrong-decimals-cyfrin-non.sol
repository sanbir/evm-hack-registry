// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  SecuritizeVault — shares come back in liquidation-token decimals (Cyfrin, 64245)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: _convertToShares divides an 18-decimal asset amount by 10**decimals()
    and multiplies by a 6-decimal NAV rate, so the minted shares are 6-decimal units
    while decimals() still returns 18. Formula preserved (@> VULN). */

contract Asset {
    string public name = "Asset";
    string public symbol = "ASSET";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _move(from, to, a);
        return true;
    }

    function _move(address from, address to, uint256 a) internal {
        require(balanceOf[from] >= a, "bal");
        balanceOf[from] -= a;
        balanceOf[to] += a;
    }
}

contract NavProvider {
    uint256 internal _rate;

    function setRate(uint256 r) external { _rate = r; } // STORY1

    function rate() external view returns (uint256) { return _rate; }
}

contract SecuritizeVault {
    Asset public asset;
    NavProvider public nav;
    uint256 public totalSupply;
    uint256 public totalAssetAmt;
    mapping(address => uint256) public balanceOf;
    uint256 public lastShares;

    constructor(Asset _asset, NavProvider _nav) {
        asset = _asset;
        nav = _nav;
    }

    function decimals() public pure returns (uint8) { return 18; }

    function totalAssets() public view returns (uint256) { return totalAssetAmt; }

    function _convertToShares(uint256 _assets) internal view returns (uint256) {
        uint256 rate = nav.rate(); // D{liquidationToken}
        uint256 decimalsFactor = 10 ** decimals(); // STORY3
        uint256 totalSharesAfterDeposit = rate * (totalAssets() + _assets) / decimalsFactor; // STORY4
        if (totalSharesAfterDeposit >= totalSupply) {
            return totalSharesAfterDeposit - totalSupply; // @> VULN: result is liquidation decimals, not share decimals
        }
        return 0;
    }

    function _convertToAssets(uint256 _shares) public view returns (uint256) {
        if (totalSupply == 0) return 0;
        uint256 rate = nav.rate();
        uint256 decimalsFactor = 10 ** decimals();
        uint256 byRate = _shares * decimalsFactor / rate;
        uint256 bySupply = _shares * totalAssets() / totalSupply;
        return byRate < bySupply ? byRate : bySupply;
    }

    /// Share decimals follow the liquidation token. Not called by run().
    function convertToSharesFixed(uint256 _assets) external view returns (uint256) {
        uint256 rate = nav.rate();
        uint256 liquidationFactor = 1e6;
        uint256 shareFactor = 10 ** decimals();
        return rate * _assets / liquidationFactor * shareFactor / shareFactor;
    }

    function deposit(uint256 _assets, address receiver) external returns (uint256 shares) {
        require(asset.transferFrom(msg.sender, address(this), _assets), "in"); // STORY2
        shares = _convertToShares(_assets);
        totalAssetAmt += _assets;
        totalSupply += shares;
        balanceOf[receiver] += shares; // STORY6
        lastShares = shares;
    }
}

contract Exploit {
    Asset public asset; // nonce 1
    NavProvider public nav; // nonce 2
    SecuritizeVault public vault; // nonce 3
    uint256 public priced;
    uint256 public constant DEPOSIT = 1000 ether;

    constructor() {
        asset = new Asset();
        nav = new NavProvider();
        vault = new SecuritizeVault(asset, nav);
        asset.mint(address(this), DEPOSIT);
    }

    function run() external {
        nav.setRate(1e6); // 1.0 in a 6-decimal liquidation token
        require(asset.approve(address(vault), DEPOSIT), "ap");
        uint256 shares = vault.deposit(DEPOSIT, address(this));
        require(vault.decimals() == 18, "dec");
        require(shares == 1_000_000_000, "shares"); // 1000 * 1e6, the report's figure
        priced = shares * 1e18 / (10 ** vault.decimals()); // STORY5 an 18-decimal integrator
        require(priced == 1_000_000_000, "priced");
        require(priced * 1e12 == DEPOSIT, "underpriced 1e12");
        require(asset.balanceOf(address(vault)) == DEPOSIT, "assets locked");
    }
}
