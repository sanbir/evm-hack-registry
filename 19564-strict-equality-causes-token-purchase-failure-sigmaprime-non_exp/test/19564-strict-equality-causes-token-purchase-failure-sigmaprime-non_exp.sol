// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    Royalties,
    NFT,
    TokenRoyaltiesHandlerFixed,
    Buyer,
    Receiver
} from "./19564-strict-equality-causes-token-purchase-failure-sigmaprime-non.sol";

contract Finding19564Test is Test {
    function test_exploit_buy_reverts_and_payment_stays() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.pay().balanceOf(address(e.handler())), 10001, "10001 stuck");
        assertEq(e.nft().ownerOf(1), address(e.handler()), "nft not delivered");
        assertFalse(e.handler().delivered(), "delivered flag");
    }

    function test_control_greater_or_equal_delivers_nft() public {
        MockToken pay = new MockToken(0);
        Royalties royalties = new Royalties();
        NFT nft = new NFT();
        Buyer buyer = new Buyer();
        Receiver a = new Receiver();
        Receiver b = new Receiver();
        TokenRoyaltiesHandlerFixed handler = new TokenRoyaltiesHandlerFixed(
            address(pay), address(royalties), address(nft), address(buyer), address(a), address(b)
        );
        nft.mint(address(handler), 1);
        pay.mint(address(handler), 10001);

        handler.purchased(1, 10001);

        assertTrue(handler.delivered(), "control delivered");
        assertEq(nft.ownerOf(1), address(buyer), "buyer owns nft");
        assertEq(pay.balanceOf(address(a)), 5000, "royalty A");
        assertEq(pay.balanceOf(address(b)), 5000, "royalty B");
        assertEq(pay.balanceOf(address(handler)), 1, "only rounding dust left");
    }
}
