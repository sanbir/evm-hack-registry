// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Sonic, EggsFixed} from "./46030-repay-does-not-decrease-borrowed-amount-as-expected-cantina.sol";

contract Finding46030Test is Test {
    function test_exploit_repay_keeps_the_debt() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.eggs().loans(address(e)), 100 ether, "debt still 100");
        assertEq(e.eggs().discarded(), 40 ether, "40 discarded");
        assertEq(e.sonic().balanceOf(address(e.eggs())), 40 ether, "40 taken");
        assertEq(e.sonic().balanceOf(address(e)), 60 ether, "borrower left with 60");
    }

    function test_control_repay_reduces_the_debt() public {
        Sonic sonic = new Sonic();
        EggsFixed eggs = new EggsFixed(sonic);
        sonic.mint(address(eggs), 100 ether);
        eggs.borrow(100 ether);
        sonic.approve(address(eggs), 40 ether);
        eggs.repay(40 ether);
        assertEq(eggs.loans(address(this)), 60 ether, "debt 60");
        assertEq(sonic.balanceOf(address(eggs)), 40 ether, "40 received");
        assertEq(sonic.balanceOf(address(this)), 60 ether, "borrower kept 60");
    }
}
