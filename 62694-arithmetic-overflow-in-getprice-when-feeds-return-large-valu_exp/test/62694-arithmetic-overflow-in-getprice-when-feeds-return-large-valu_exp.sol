// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    ChainlinkOracleComposite,
    ChainlinkOracleCompositeFixed,
    LendingMarket,
    MockAggregator,
    MiniToken
} from "./62694-arithmetic-overflow-in-getprice-when-feeds-return-large-valu.sol";

contract GetPriceOverflowTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant COLLATERAL = 1000 ether;

    function test_exploit_largeFeedPrice_bricksOracle_freezesMarket() public {
        Exploit e = new Exploit();
        e.run();

        // HARM 1: the buggy composite oracle overflow-reverts on a valid $1M feed.
        assertTrue(e.buggyReverted(), "buggy getPrice() must revert on a large valid price");

        // HARM 2: the dependent market can no longer price or liquidate -> collateral frozen.
        assertTrue(e.marketFrozen(), "dependent market must be frozen when the oracle bricks");
        assertEq(e.lockedCollateral(), COLLATERAL, "all deposited collateral is frozen");

        // Marker records the locked magnitude at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), COLLATERAL, "marker records frozen collateral at SINK");
        assertEq(e.sinkMarkerBalance(), COLLATERAL, "sink marker balance matches frozen collateral");

        // Real collateral tokens are genuinely stuck in the bricked market.
        MiniToken collateral = LendingMarket(e.marketAddr()).collateral();
        assertEq(collateral.balanceOf(e.marketAddr()), COLLATERAL, "collateral truly locked in market");

        // CONTROL 1 (fix): OZ Math.mulDiv prices the identical $1M feed cleanly.
        // rate = 1e14 * 10^(36-8) = 1e42; compositePrice = mulDiv(1e36, 1e42, 1e36) = 1e42.
        assertEq(e.fixedPrice(), 1e42, "fixed oracle returns a finite composite price on the same feed");

        // CONTROL 2 (below-threshold): the SAME buggy oracle works at a valid $50k feed.
        // rate = 5e12 * 10^28 = 5e40; compositePrice = (1e36 * 5e40)/1e36 = 5e40.
        assertEq(e.belowThresholdPrice(), 5e40, "buggy oracle prices a below-threshold feed without overflow");
    }

    function test_directOverflow_and_fixIsFinite() public {
        // Reproduce the exact arithmetic-overflow revert directly against the buggy
        // oracle, and confirm the fixed variant is finite on the same input.
        Exploit e = new Exploit();
        e.run(); // leaves the feed at the $1M bricking answer

        ChainlinkOracleComposite buggy = ChainlinkOracleComposite(e.oracleAddr());
        vm.expectRevert(stdError.arithmeticError);
        buggy.getPrice();

        ChainlinkOracleCompositeFixed fixedOracle = ChainlinkOracleCompositeFixed(e.fixedAddr());
        assertEq(fixedOracle.getPrice(), 1e42, "fixed variant returns finite price where buggy overflows");
    }
}
