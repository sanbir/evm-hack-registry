// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./61051-attacker-can-get-unlimited-loan-for-some-minimum-deposit-due.sol";

contract Finding61051Test is Test {
    function test_exploit_borrows_8_eth_against_1_eth() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.loans().lastEffective(), 8.25 ether, "inflated");
        assertEq(e.token().balanceOf(address(e)), 8 ether, "borrowed");
        assertEq(e.loans().colLength(address(e)), 11, "dups");
    }

    function test_control_one_pool_entry_rejects_the_borrow() public {
        Exploit e = new Exploit();
        e.runFixed();
        assertEq(e.loans().colLength(address(e)), 1, "once");
        assertEq(e.token().balanceOf(address(e)), 0.75 ether, "fair");
        assertEq(e.loans().lastEffective(), 0.75 ether, "onceValue");
    }
}
