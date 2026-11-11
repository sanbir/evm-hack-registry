// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Stack} from "./19131-h-2-ussdrebalancersolsellussdbuycollateral-the-check-of-whet.sol";

contract Finding19131Test is Test {
    function test_exploit_sells_dai_that_should_stay() public {
        Exploit e = new Exploit();
        e.run();
        Stack s = e.stack();
        assertEq(s.rebalancer().lastDaiBought(), 2000e18, "bought 2000 DAI");
        assertEq(s.rebalancer().portionsFinal(), 2, "two underweight collaterals");
        assertEq(s.ussd().wronglySold(), 1000e18, "buggy path sells 1000 DAI");
        assertEq(s.dai().balanceOf(address(s.ussd())), 0, "treasury DAI left");
        assertEq(s.dai().balanceOf(address(s.sink())), 1000e18, "sink received the sold DAI");
        assertEq(s.coll().balanceOf(address(s.ussd())), 1000e18, "COLL still bought with the other slice");
    }

    function test_control_and_keeps_the_dai_slice() public {
        Stack fixedStack = new Stack(true);
        fixedStack.go();
        assertEq(fixedStack.ussd().wronglySold(), 0, "AND skips the DAI path");
        assertEq(fixedStack.dai().balanceOf(address(fixedStack.ussd())), 1000e18, "1000 DAI stays");
        assertEq(fixedStack.dai().balanceOf(address(fixedStack.sink())), 0, "sink gets nothing");
        assertEq(fixedStack.coll().balanceOf(address(fixedStack.ussd())), 1000e18, "COLL buy unchanged");
        assertEq(fixedStack.rebalancer().lastDaiBought(), 2000e18, "same 2000 DAI buy");
    }
}
