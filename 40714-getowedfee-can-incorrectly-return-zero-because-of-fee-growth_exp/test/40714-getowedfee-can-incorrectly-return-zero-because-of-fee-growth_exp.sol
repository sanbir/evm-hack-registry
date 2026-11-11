// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Stack} from "./40714-getowedfee-can-incorrectly-return-zero-because-of-fee-growth.sol";

contract Finding40714Test is Test {
    function test_exploit_pays_zero_instead_of_3e18() public {
        Exploit e = new Exploit();
        e.run();
        Stack s = e.stack();
        assertEq(s.vault().paid(), 0, "buggy owed fee");
        assertEq(e.fair(), 3e18 - 1, "unchecked fee");
        assertEq(s.token().balanceOf(address(s.lp())), 0, "LP received nothing");
        assertEq(s.token().balanceOf(address(s.vault())), 3e18 - 1, "fees stayed in the vault");
    }

    function test_control_pays_the_lp_3e18() public {
        Stack fixedStack = new Stack(true);
        fixedStack.go();
        assertEq(fixedStack.vault().paid(), 3e18 - 1, "fixed owed fee");
        assertEq(fixedStack.token().balanceOf(address(fixedStack.lp())), 3e18 - 1, "LP paid");
        assertEq(fixedStack.token().balanceOf(address(fixedStack.vault())), 0, "vault forwarded the fee");
    }
}
