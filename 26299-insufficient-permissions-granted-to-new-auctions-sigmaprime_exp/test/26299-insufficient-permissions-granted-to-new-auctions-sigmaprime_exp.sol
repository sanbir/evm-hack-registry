// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    CollateralManagerFixed,
    CollateralToken,
    Exploit,
    TermAuction
} from "./26299-insufficient-permissions-granted-to-new-auctions-sigmaprime.sol";

contract Finding26299Test is Test {
    uint256 internal constant AMOUNT = 4_000 ether;

    function test_exploit_4000_collateral_stuck() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.completeReverted(), "settle reverted");
        assertTrue(e.refundReverted(), "refund reverted");
        assertEq(e.stuck(), AMOUNT, "4,000 stuck");
        assertEq(e.token().balanceOf(address(e.auction())), AMOUNT, "auction balance");
        assertFalse(e.auction().completed(), "auction did not complete");
    }

    function test_control_role_lets_the_auction_complete() public {
        CollateralToken token = new CollateralToken();
        CollateralManagerFixed manager = new CollateralManagerFixed();
        TermAuction auction = new TermAuction(manager, token);

        token.mint(address(this), AMOUNT);
        manager.reopenToNewAuction(address(auction));
        assertTrue(manager.hasRole(manager.AUCTION_LOCKER(), address(auction)), "role granted");

        token.approve(address(auction), AMOUNT);
        auction.lockBid(AMOUNT);
        auction.complete();

        assertTrue(auction.completed(), "auction completed");
        assertEq(token.balanceOf(address(auction)), 0, "auction released the bid");
        assertEq(token.balanceOf(address(manager)), AMOUNT, "4,000 moved to the manager");
        assertEq(auction.escrow(), 0, "escrow cleared");
    }
}
