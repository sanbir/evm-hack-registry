// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./55210-c-03-unrestricted-diamondcut-allows-unauthorized-facet-modif.sol";

contract UnrestrictedDiamondCutTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), e.TVL(), "full TVL stolen");
        assertEq(e.token().balanceOf(address(e.diamond())), 0, "diamond empty");
    }

    function test_ownerBootstrapStillWorks() public {
        Exploit e = new Exploit();
        // diamond has TVL before attack
        assertEq(e.token().balanceOf(address(e.diamond())), e.TVL());
    }
}
