// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, ERC20Mini, AskBook, LOBFixed} from "./56837-incorrect-condition-for-post-only-orders-mixbytes-none-xpres.sol";

contract PostOnlyFeeTest is Test {
    function test_postOnlyBidPaysAggressiveCommission() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.orderId(), 1, "post_only bid was matched");
        assertEq(exp.feeCharged(), 100 ether, "aggressive commission is 100 ether");
        assertEq(exp.quote().balanceOf(address(exp.lob())), 100 ether, "100 ether pulled as fee");
    }

    function test_control_correctSignChargesNothing() public {
        ERC20Mini quote = new ERC20Mini("QUOTE");
        AskBook book = new AskBook();
        LOBFixed lob = new LOBFixed(book, quote);
        quote.mint(address(this), 100 ether);
        quote.approve(address(lob), type(uint256).max);

        uint64 id = lob.placeOrder(90, 10_000, true);

        assertEq(id, 0, "post_only bid must not match");
        assertEq(lob.feesTaken(), 0, "no aggressive commission");
        assertEq(quote.balanceOf(address(lob)), 0, "control does not pull 100 ether");
    }
}
