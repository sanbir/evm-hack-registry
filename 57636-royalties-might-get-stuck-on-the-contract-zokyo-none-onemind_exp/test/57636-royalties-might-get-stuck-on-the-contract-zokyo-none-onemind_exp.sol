// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    PlatformAuctionFixed
} from "./57636-royalties-might-get-stuck-on-the-contract-zokyo-none-onemind.sol";

contract Finding57636Test is Test {
    address internal constant SELLER = 0x0000000000000000000000000000000000005e11;

    function test_exploit_zero_royalty_receiver_sticks_royalty() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.royalty(), 100 ether, "royalty");
        assertEq(e.sent(), false, "not transferred");
        assertEq(e.sellerGot(), 900 ether, "seller short");
        assertEq(e.stuck(), 100 ether, "100 stuck");
        assertEq(e.currency().balanceOf(address(e.auction())), 100 ether, "auction balance");
    }

    function test_control_unsent_royalty_is_not_subtracted() public {
        MiniToken currency = new MiniToken();
        PlatformAuctionFixed auction = new PlatformAuctionFixed(currency, SELLER);
        currency.mint(address(this), 1000 ether);
        currency.approve(address(auction), 1000 ether);
        auction.renounceOwner();
        auction.settle(1000 ether);
        assertEq(auction.lastSent(), false, "not sent");
        assertEq(currency.balanceOf(SELLER), 1000 ether, "seller whole");
        assertEq(currency.balanceOf(address(auction)), 0, "nothing stuck");
    }
}
