// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Token, EasyAuction, GnosisTrade} from "./57069-all-auction-initiation-attempts-may-fail-trailofbits-none-re.sol";

/// @dev Approve the full budget, but auction only budget / (1 + fee).
contract TradeFixed {
    Token public sell;
    EasyAuction public gnosis;
    uint256 public auctionId;

    constructor(Token sell_, EasyAuction gnosis_) {
        sell = sell_;
        gnosis = gnosis_;
    }

    function init(uint256 budget) external {
        uint256 actual = budget * gnosis.FEE_DENOMINATOR() / (gnosis.FEE_DENOMINATOR() + gnosis.feeNumerator());
        sell.approve(address(gnosis), budget);
        auctionId = gnosis.initiateAuction(sell, actual);
    }
}

contract Finding57069Test is Test {
    function test_exploit_auction_reverts_and_collateral_stays() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.sell().balanceOf(address(e.trade())), 10100, "10100 unsold");
        assertEq(e.trade().auctionId(), 0, "no auction");
        assertEq(e.auction().bids(), 0, "no bidder");
    }

    function test_control_starts_the_auction_and_a_bidder_pays() public {
        Token sell = new Token();
        Token buy = new Token();
        EasyAuction auction = new EasyAuction();
        TradeFixed trade = new TradeFixed(sell, auction);
        sell.mint(address(trade), 10100);
        trade.init(10100);

        assertEq(trade.auctionId(), 1, "auction started");
        assertEq(sell.balanceOf(address(trade)), 0, "collateral left the trade");
        assertEq(sell.balanceOf(address(auction)), 10100, "auction holds the collateral");

        buy.mint(address(this), 5000);
        buy.approve(address(auction), 5000);
        auction.bid(buy, 5000);
        assertEq(auction.bids(), 5000, "bidder paid 5000");
        assertEq(buy.balanceOf(address(auction)), 5000, "auction received the bid");
    }
}
