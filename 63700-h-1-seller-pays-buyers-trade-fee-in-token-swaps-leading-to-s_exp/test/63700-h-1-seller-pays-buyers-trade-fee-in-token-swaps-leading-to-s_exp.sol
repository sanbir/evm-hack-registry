// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Cash, Treasury, Seller, MarketControllerFixed} from
    "./63700-h-1-seller-pays-buyers-trade-fee-in-token-swaps-leading-to-s.sol";

contract Finding63700Test is Test {
    function test_exploit_seller_receives_594_of_600() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.cash().balanceOf(address(e.seller())), 594 ether, "seller 594");
        assertEq(e.cash().balanceOf(address(e.treasury())), 6 ether, "fee 6");
        assertEq(e.market().fairSeller(), 600 ether, "fair 600");
        assertEq(e.market().fairBuyerCost(), 606 ether, "buyer should pay 606");
        assertEq(600 ether - e.cash().balanceOf(address(e.seller())), 6 ether, "shortfall");
    }

    function test_control_seller_receives_full_payment() public {
        Cash cash = new Cash();
        Treasury treasury = new Treasury();
        Seller seller = new Seller();
        MarketControllerFixed fixedMarket = new MarketControllerFixed(cash);
        fixedMarket.configure(address(treasury), address(seller));
        cash.mint(address(fixedMarket), 606 ether);
        fixedMarket._executeTokenSwap(address(this), 1_000 ether, 6_000);
        assertEq(cash.balanceOf(address(seller)), 600 ether, "seller 600");
        assertEq(cash.balanceOf(address(treasury)), 6 ether, "fee still 6");
        assertEq(cash.balanceOf(address(fixedMarket)), 0, "buyer paid the fee on top");
        assertEq(fixedMarket.netPayment(), 600 ether, "net is the full price");
    }
}
