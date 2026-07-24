// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64857-h-09-dos-of-launchpad-graduation-via-addliquidity-with-1-wei.sol";

contract GraduationDosTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.dosed(), "graduation DOS");
        assertFalse(e.launchpad().graduated(), "not graduated");
    }
}
