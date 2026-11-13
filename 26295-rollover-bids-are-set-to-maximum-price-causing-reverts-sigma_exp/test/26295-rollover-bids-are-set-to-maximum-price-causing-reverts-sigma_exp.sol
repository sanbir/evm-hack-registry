// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    TermAuctionFixed,
    Bid,
    Receiver
} from "./26295-rollover-bids-are-set-to-maximum-price-causing-reverts-sigma.sol";

contract Finding26295Test is Test {
    function test_exploit_rollover_clear_reverts_and_tokens_stay() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.purchase().balanceOf(address(e.auction())), 1_000 ether, "1000 stuck");
        assertEq(e.purchase().balanceOf(e.bidder()), 0, "bidder unpaid");
        assertFalse(e.auction().cleared(), "not cleared");
    }

    function test_control_submitted_price_clears_and_pays() public {
        MockToken purchase = new MockToken();
        Receiver bidder = new Receiver();
        TermAuctionFixed auction = new TermAuctionFixed(address(purchase), address(bidder));
        purchase.mint(address(auction), 1_000 ether);
        Bid memory filled = auction._fillRevealedBidsForAuctionClearing(
            Bid({isRollover: true, bidPriceRevealed: 120})
        );

        auction.clear(100, filled.bidPriceRevealed);

        assertEq(filled.bidPriceRevealed, 120, "submitted price kept");
        assertEq(auction.clearingPrice(), 110, "mid price");
        assertEq(purchase.balanceOf(address(bidder)), 1_000 ether, "1000 paid");
        assertEq(purchase.balanceOf(address(auction)), 0, "auction empty");
        assertTrue(auction.cleared(), "cleared");
    }
}
