// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65374-users-can-participate-in-an-infinite-number-of-games-they-ha.sol";

contract FreeRideCrossGameTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.tok().balanceOf(address(e.attacker())), e.PAID_FEE(), "free-rider claimed paid pool");
        assertEq(e.tok().balanceOf(address(e.sm())), 0, "pool empty");
    }
}
