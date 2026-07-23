// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65379-if-multiple-users-call-defaultsessionassertresults-all-but-t.sol";

contract DoubleAssertBondTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.usdc().balanceOf(address(e.userA())), e.BOND(), "A recovered");
        assertEq(e.usdc().balanceOf(address(e.userB())), 0, "B lost bond");
        assertEq(e.usdc().balanceOf(address(e.oo())), e.BOND(), "B bond stuck");
    }
}
