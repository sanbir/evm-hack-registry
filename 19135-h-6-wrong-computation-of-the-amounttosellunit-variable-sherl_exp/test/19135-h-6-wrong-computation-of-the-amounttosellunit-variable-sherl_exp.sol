// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Stack} from "./19135-h-6-wrong-computation-of-the-amounttosellunit-variable-sherl.sol";

contract Finding19135Test is Test {
    function test_exploit_sells_zero_instead_of_250e18() public {
        Exploit e = new Exploit();
        e.run();
        Stack s = e.stack();
        assertEq(s.rebalancer().soldUnits(), 0, "buggy amountToSellUnits");
        assertEq(e.fairUnits(), 250e18, "fair amount");
        assertEq(s.rebalancer().daiRaised(), 0, "DAI raised by the bug");
        assertEq(s.coll().balanceOf(address(s.ussd())), 1000e18, "COLL untouched");
    }

    function test_control_sells_250e18_and_raises_250e18_dai() public {
        Stack fixedStack = new Stack(true);
        fixedStack.go(250e6);
        assertEq(fixedStack.rebalancer().soldUnits(), 250e18, "corrected amount");
        assertEq(fixedStack.rebalancer().daiRaised(), 250e18, "DAI raised");
        assertEq(fixedStack.coll().balanceOf(address(fixedStack.ussd())), 750e18, "COLL left");
        assertEq(fixedStack.dai().balanceOf(address(fixedStack.ussd())), 250e18, "DAI received");
    }
}
