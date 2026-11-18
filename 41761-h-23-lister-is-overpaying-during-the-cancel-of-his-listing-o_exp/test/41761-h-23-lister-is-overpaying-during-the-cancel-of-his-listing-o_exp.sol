// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./41761-h-23-lister-is-overpaying-during-the-cancel-of-his-listing-o.sol";

contract Finding41761Test is Test {
    function test_cancel_charges_used_tax_twice() public {
        vm.warp(1_700_000_000);
        Exploit e = new Exploit();
        e.run();
        assertEq(e.listings().lastRequired(), 0.9 ether, "pulled 0.9");
        assertEq(e.listings().lastFees(), 0.1 ether, "used tax");
        assertEq(e.token().balanceOf(address(e)), 0, "pocket gone");
        assertEq(e.token().balanceOf(0x000000000000000000000000000000000000dEaD), 1 ether, "burned the full 1 COL");
        assertEq(e.token().balanceOf(address(e.fees())), 0.1 ether, "fee sink");
        assertEq(e.overpay(), 0.1 ether, "second payment");
    }
}
