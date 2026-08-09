// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    BackstopMarket,
    BackstopMarketFixed,
    MiniToken,
    Order,
    Side,
    TiF,
    BookType,
    PostOnlyOrderWouldBeFilled
} from "./64835-h-02-backstop-bid-side-frozen-by-tick-size-constraint-code4r.sol";

contract BackstopBidFrozenByTickSizeTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant TICK = 1e15;
    uint256 internal constant BID_AMOUNT = 5_000 ether;

    function test_exploit_backstopBidFrozenAtMinTick() public {
        Exploit e = new Exploit();
        e.run();

        // The attacker's SELL parked at the smallest grid point becomes best ask.
        assertEq(e.bestAskAfterPark(), TICK, "best ask parked at min tick");

        // HARM: the only legal minimum backstop BID is frozen forever.
        assertTrue(e.bidBlocked(), "min-tick backstop bid must revert PostOnlyOrderWouldBeFilled");

        // No lower LEGAL positive price exists: sub-tick and zero are both illegal.
        assertTrue(e.subTickRejected(), "sub-tick price rejected (off grid)");
        assertTrue(e.zeroPriceRejected(), "zero maker price rejected");

        // Negative control on the SAME buggy code: ask one tick higher -> bid posts.
        assertTrue(e.controlBidPosts(), "bid posts when ask is one tick higher");

        // Frozen backstop-bid liquidity recorded at the SINK marker.
        assertEq(e.frozenBidAmount(), BID_AMOUNT, "frozen bid magnitude");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), BID_AMOUNT, "marker records frozen bid at SINK");
        assertEq(e.sinkMarkerBalance(), BID_AMOUNT, "sink marker balance");
    }

    // Direct assertion of the exact revert selector on the vulnerable book.
    function test_exploit_revertSelectorIsPostOnly() public {
        BackstopMarket book = new BackstopMarket(TICK);

        // Park the SELL backstop maker at the minimum tick.
        book.placeOrder(Order({price: TICK, amount: BID_AMOUNT, side: Side.SELL, tif: TiF.MOC}), BookType.BACKSTOP);
        assertEq(book.getBestAsk(), TICK, "ask at min tick");

        // The min-tick backstop BID reverts with PostOnlyOrderWouldBeFilled.
        vm.expectRevert(PostOnlyOrderWouldBeFilled.selector);
        book.placeOrder(Order({price: TICK, amount: BID_AMOUNT, side: Side.BUY, tif: TiF.MOC}), BookType.BACKSTOP);

        // The bid side never received the order.
        assertEq(book.numBids(), 0, "no bid could be posted -> bid side frozen");
    }

    // Negative control against the FIXED variant: the one-tick buffer lets the
    // min-tick backstop bid post successfully.
    function test_control_fixedVariant_allowsMinTickBid() public {
        BackstopMarketFixed book = new BackstopMarketFixed(TICK);

        book.placeOrder(Order({price: TICK, amount: BID_AMOUNT, side: Side.SELL, tif: TiF.MOC}), BookType.BACKSTOP);
        assertEq(book.getBestAsk(), TICK, "ask at min tick");

        // With the strict `<` buffer, the min-tick post-only bid is NOT treated
        // as crossing and posts successfully.
        book.placeOrder(Order({price: TICK, amount: BID_AMOUNT, side: Side.BUY, tif: TiF.MOC}), BookType.BACKSTOP);
        assertEq(book.numBids(), 1, "fixed variant posts the backstop bid");
    }
}
