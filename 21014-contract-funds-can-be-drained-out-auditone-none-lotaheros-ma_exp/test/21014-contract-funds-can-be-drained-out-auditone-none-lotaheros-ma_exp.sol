// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, TradingPost, Attacker} from "./21014-contract-funds-can-be-drained-out-auditone-none-lotaheros-ma.sol";

contract TradingPostFixed is TradingPost {
    function cancelTradeOer(uint256 id) external override {
        Order memory o = orders[id];
        require(o.open && o.seller == msg.sender, "order");
        orders[id].open = false;
        (bool ok,) = msg.sender.call{value: o.price}("");
        require(ok, "refund");
    }
}

contract Finding21014Test is Test {
    function test_exploit_cancel_reenters_until_the_post_is_empty() public {
        Exploit e = new Exploit();
        e.run{value: 6 ether}();
        assertEq(address(e.attacker()).balance, 6 ether, "6 ETH drained");
        assertEq(address(e.post()).balance, 0, "post empty");
    }

    function test_control_close_first_refunds_only_the_order() public {
        TradingPostFixed post = new TradingPostFixed();
        Attacker attacker = new Attacker(TradingPost(address(post)));
        post.seed(7, address(attacker), 1 ether);
        post.fund{value: 6 ether}();
        attacker.go(7);
        assertEq(address(attacker).balance, 1 ether, "only the 1 ETH order");
        assertEq(address(post).balance, 5 ether, "other sellers keep 5 ETH");
    }
}
