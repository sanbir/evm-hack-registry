// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Stack} from "./40819-dos-in-distribute-cantina-none-zerolend-pdf.sol";

contract Finding40819Test is Test {
    uint256 constant TS = 1_700_000_000;

    function test_exploit_sticks_1000e18_rewards() public {
        vm.warp(TS);
        Exploit e = new Exploit();
        e.run();
        Stack s = e.stack();
        assertFalse(s.distributed(), "distribute reverted");
        assertEq(s.token().balanceOf(address(s.staking())), 1000e18, "stuck in staking");
        assertEq(s.token().balanceOf(s.user()), 0, "user received nothing");
    }

    function test_control_user_receives_1000e18() public {
        vm.warp(TS);
        Stack fixedStack = new Stack(true);
        fixedStack.go();
        assertTrue(fixedStack.distributed(), "distribute ran");
        assertEq(fixedStack.token().balanceOf(address(fixedStack.staking())), 0, "staking emptied");
        assertEq(fixedStack.token().balanceOf(fixedStack.user()), 1000e18, "user received the epoch");
    }
}
