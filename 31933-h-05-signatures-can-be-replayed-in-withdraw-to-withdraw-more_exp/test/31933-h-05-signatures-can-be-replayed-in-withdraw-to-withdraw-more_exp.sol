// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./31933-h-05-signatures-can-be-replayed-in-withdraw-to-withdraw-more.sol";

contract FindingTest is Test {
    function test_attack() public {
        vm.warp(10 days);
        Exploit e = new Exploit();
        e.run();

        assertEq(e.firstPaid(), 40 ether);
        assertEq(e.secondPaid(), 30 ether);
        assertEq(e.token().balanceOf(e.TO()), 70 ether);
    }

    function test_control() public {
        vm.warp(10 days);
        Exploit e = new Exploit();
        e.runControl();
    }
}
