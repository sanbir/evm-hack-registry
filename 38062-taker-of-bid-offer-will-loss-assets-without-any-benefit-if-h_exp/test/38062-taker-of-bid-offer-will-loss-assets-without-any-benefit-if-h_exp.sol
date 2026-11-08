// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {
    Exploit,
    MockToken,
    TokenManager,
    DeliveryPlace,
    BidMaker
} from "./38062-taker-of-bid-offer-will-loss-assets-without-any-benefit-if-h.sol";

/// Recommended fix: reject a partial settle before any token moves.
contract FixedDelivery {
    function settle(uint256 settledPoints, uint256 stockPoints) external pure {
        require(settledPoints == stockPoints, "partial");
    }
}

contract Finding38062Test is Test {
    function test_exploit_partial_settle_pays_maker_and_takes_points() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.pointsBefore(), 100e18, "log start");
        assertEq(e.pointsAfter(), 97e18, "taker lost 3 POINT");
        assertEq(e.takerUsdc(), 0, "taker USDC");
        assertEq(e.makerUsdc(), 6e18, "maker took collateral");
        assertEq(e.makerPoints(), 3e18, "maker received the points");
        assertEq(e.profit(), 6e18, "profit");
        assertTrue(e.secondReverted(), "stock not closed");
        assertEq(e.delivery().lastCollateralFee(), 6e18, "fee");
        assertEq(e.usdc().balanceOf(address(e.tokenManager())), 0, "escrow left");

        console.log("taker POINT before", e.pointsBefore());
        console.log("taker POINT after ", e.pointsAfter());
        console.log("taker USDC received", e.takerUsdc());
        console.log("maker USDC collateral", e.makerUsdc());
        console.log("maker POINT received", e.makerPoints());
    }

    function test_control_full_settlement_returns_collateral_to_taker() public {
        MockToken usdc = new MockToken("USD Coin", "USDC");
        MockToken point = new MockToken("Point", "POINT");
        TokenManager tm = new TokenManager(usdc, point);
        DeliveryPlace delivery = new DeliveryPlace(tm);
        BidMaker maker = new BidMaker();

        point.mint(address(this), 100e18);
        usdc.mint(address(tm), 6e18);
        delivery.configure(
            address(0xA11CE),
            address(0xBEEF),
            address(maker),
            address(this),
            address(usdc),
            address(point),
            0.01e18,
            12_000,
            500,
            5e18
        );

        point.approve(address(tm), type(uint256).max);
        delivery.settleAskTaker(address(0xBEEF), 500);

        assertEq(point.balanceOf(address(this)), 95e18, "paid 5 POINT");
        assertEq(usdc.balanceOf(address(this)), 6e18, "collateral returned");
        assertEq(usdc.balanceOf(address(maker)), 0, "maker was paid");
        assertEq(point.balanceOf(address(maker)), 5e18, "maker got the points");
        assertEq(delivery.lastSettledPoints(), 500, "full");
        assertTrue(delivery.stockFinished(), "closed");

        console.log("control taker USDC", usdc.balanceOf(address(this)));
        console.log("control maker USDC", usdc.balanceOf(address(maker)));
    }

    function test_control_fixed_partial_reverts_and_moves_nothing() public {
        FixedDelivery fixedDelivery = new FixedDelivery();
        MockToken point = new MockToken("Point", "POINT");
        point.mint(address(this), 100e18);

        vm.expectRevert(bytes("partial"));
        fixedDelivery.settle(300, 500);

        assertEq(point.balanceOf(address(this)), 100e18, "points moved");
    }
}
