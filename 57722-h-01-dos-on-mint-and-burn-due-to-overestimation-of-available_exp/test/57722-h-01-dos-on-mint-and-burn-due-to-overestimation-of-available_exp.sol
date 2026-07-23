// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./57722-h-01-dos-on-mint-and-burn-due-to-overestimation-of-available.sol";

contract CompoundOverestimateDoSTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.burnDoS(), "burn DoS");
        assertTrue(e.mintDoS(), "mint DoS");
        assertEq(e.overestimatedLiq(), 14, "overestimate");
    }
}
