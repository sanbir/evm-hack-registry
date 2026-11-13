// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, OpenBook, FeeToken, OpenParams} from "./40715-openposition-should-not-charge-fees-on-marginfrom-or-charge.sol";

contract Finding40715Test is Test {
    function test_marginFrom_is_charged() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.book().feesTaken(), 60, "protocol fee");
        assertEq(e.book().fairFee(0), 0, "fair fee on zero borrow");
        assertEq(e.token().balanceOf(address(e.book())), 60, "book balance");
        console2.log("fee charged", e.book().feesTaken());
        console2.log("fair fee", e.book().fairFee(0));
    }

    function test_control_charges_only_borrowed() public {
        FeeToken token = new FeeToken();
        OpenBook book = new OpenBook(token);
        token.mint(address(this), 6000);
        token.approve(address(book), type(uint256).max);
        uint256 charged = book.openPosition(OpenParams({marginFrom: 0, marginTo: 2}));
        assertEq(charged, 0, "marginTo does not pay the marginFrom fee");
        assertEq(book.fairFee(0), 0, "recommended base is the borrow");
        console2.log("control fee", charged);
    }
}
