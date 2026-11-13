// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    MarketFixed,
    Token
} from "./60731-incorrect-accounting-in-removeorder-leading-to-loss-of-orde.sol";

contract Finding60731Test is Test {
    function test_exploit_cancel_b_locks_order_a() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.refunded(), 40 ether, "refund was not B");
        assertEq(e.stuck(), 100 ether, "A was not locked");
        assertEq(e.token().balanceOf(address(e.market())), 100 ether);
        assertEq(e.market().getBestOrder(1), e.idB());
    }

    function test_control_cancel_removes_only_the_requested_order() public {
        Token token = new Token("Talent", "TLNT", 18);
        MarketFixed market = new MarketFixed(token);
        token.mint(address(this), 140 ether);
        token.approve(address(market), 140 ether);
        uint256 idA = market.addOrder(1, 100 ether);
        uint256 idB = market.addOrder(1, 40 ether);
        market.cancelOrder(idB);
        (,,, bool activeA, bool onBookA) = market.orders(idA);
        assertTrue(activeA && onBookA, "A left the book");
        assertEq(token.balanceOf(address(market)), 100 ether);
        market.cancelOrder(idA);
        assertEq(token.balanceOf(address(market)), 0, "A escrow stayed");
        assertEq(token.balanceOf(address(this)), 140 ether, "maker did not get both refunds");
    }
}
