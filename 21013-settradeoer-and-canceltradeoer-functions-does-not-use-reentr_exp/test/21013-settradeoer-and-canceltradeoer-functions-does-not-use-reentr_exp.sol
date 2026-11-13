// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Gold, TradingPost, Attacker} from "./21013-settradeoer-and-canceltradeoer-functions-does-not-use-reentr.sol";

contract TradingPostFixed is TradingPost {
    constructor(Gold gold_) TradingPost(gold_) {}

    function setTradeOer(uint256 id) external payable override {
        Order memory prev = orders[id];
        require(prev.seller == msg.sender && prev.open, "order");
        orders[id].open = false;
        gold.transfer(msg.sender, BONUS);
        (bool ok,) = msg.sender.call{value: prev.price}("");
        require(ok, "refund");
    }
}

contract Finding21013Test is Test {
    function test_exploit_setTradeOer_reenters_and_drains_escrow() public {
        Exploit e = new Exploit();
        e.run{value: 5 ether}();
        assertEq(address(e.attacker()).balance, 5 ether, "5 ETH of other sellers taken");
        assertEq(e.gold().balanceOf(address(e.attacker())), 500, "500 gold bonus pulled");
        assertEq(address(e.post()).balance, 0, "post empty");
    }

    function test_control_close_before_call_pays_once() public {
        Gold gold = new Gold();
        TradingPostFixed post = new TradingPostFixed(gold);
        Attacker attacker = new Attacker(TradingPost(address(post)));
        post.seed(1, address(attacker), 1 ether);
        post.fundGold(500);
        post.fund{value: 5 ether}();
        attacker.go(1);
        assertEq(address(attacker).balance, 1 ether, "only the 1 ETH order");
        assertEq(gold.balanceOf(address(attacker)), 100, "one bonus");
        assertEq(address(post).balance, 4 ether, "other escrow stays");
    }
}
