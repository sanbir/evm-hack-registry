// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Prem,
    BlackScholes,
    Seller,
    StrategyFixed
} from "./57738-h-01-option-premium-calculation-underprices-options-pashov-a.sol";

contract Finding57738Test is Test {
    function test_buyer_pays_the_short_period_and_the_seller_is_short() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.chargedAmt(), 7 ether, "7-day premium is 7 ether");
        assertGt(e.fairAmt(), e.chargedAmt(), "fair premium is higher");
        assertEq(e.sellerShort(), e.fairAmt() - e.chargedAmt(), "seller is short the gap");
        assertEq(e.prem().balanceOf(address(e)), 1000 ether + e.sellerShort(), "buyer kept the discount");
        assertEq(e.prem().balanceOf(address(e.seller())), 1000 ether - e.sellerShort(), "seller reserve is short");
        uint256 duration = e.strategy().actualDuration(e.PERIOD());
        assertEq(e.fairAmt(), e.NOTIONAL() * duration / 365 days, "fair matches the maturity");
    }

    function test_control_charges_the_maturity_and_the_short_is_zero() public {
        Prem prem = new Prem();
        BlackScholes bs = new BlackScholes();
        Seller seller = new Seller();
        StrategyFixed strategy = new StrategyFixed(prem, bs, address(seller));
        prem.mint(address(this), 1000 ether);
        prem.mint(address(seller), 1000 ether);
        prem.approve(address(strategy), type(uint256).max);
        seller.approve(prem, address(strategy), type(uint256).max);
        uint256 fair = bs.optionPrices(strategy.actualDuration(7 days), 365 ether);
        uint256 charged = strategy.buy(365 ether, 7 days);
        assertEq(charged, fair, "control charges the fair premium");
        assertEq(strategy.fair() - strategy.charged(), 0, "short is 0");
        assertEq(prem.balanceOf(address(this)), 1000 ether, "buyer paid the fair premium");
        assertEq(prem.balanceOf(address(seller)), 1000 ether, "seller is not short");
    }
}
