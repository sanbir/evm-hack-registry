// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    SellerFinancingFixed,
    Token
} from "./60495-locked-funds-when-fulfilling-seaport-orders-quantstamp-nifty.sol";

contract Finding60495Test is Test {
    function test_exploit_locks_the_non_weth_offer() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stuck(), 500 ether, "SIDE was not locked");
        assertEq(e.extra().balanceOf(address(e.financing())), 500 ether);
        assertEq(e.buyerWeth(), 1 ether, "buyer missed WETH");
        assertEq(e.extra().balanceOf(address(e)), 0);
    }

    function test_control_rejects_a_second_offer_item() public {
        Token weth = new Token("Wrapped Ether", "WETH", 18);
        Token extra = new Token("Side Token", "SIDE", 18);
        SellerFinancingFixed fixedFin = new SellerFinancingFixed(weth);
        weth.mint(address(this), 1 ether);
        extra.mint(address(this), 500 ether);
        weth.approve(address(fixedFin), 1 ether);
        extra.approve(address(fixedFin), 500 ether);

        SellerFinancingFixed.OfferItem[] memory offer = new SellerFinancingFixed.OfferItem[](2);
        offer[0] = SellerFinancingFixed.OfferItem(address(weth), 1 ether);
        offer[1] = SellerFinancingFixed.OfferItem(address(extra), 500 ether);
        (bool ok,) = address(fixedFin).call(
            abi.encodeWithSelector(SellerFinancingFixed.fulfillOrder.selector, offer, uint256(1 ether))
        );
        assertFalse(ok, "two-item offer was accepted");
        assertEq(extra.balanceOf(address(this)), 500 ether, "seller lost SIDE");
        assertEq(extra.balanceOf(address(fixedFin)), 0, "SIDE was pulled");
    }
}
