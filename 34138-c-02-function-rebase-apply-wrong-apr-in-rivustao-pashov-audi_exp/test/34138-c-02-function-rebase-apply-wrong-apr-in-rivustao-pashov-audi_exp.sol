// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./34138-c-02-function-rebase-apply-wrong-apr-in-rivustao-pashov-audi.sol";

contract FindingTest is Test {
    function test_attack() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.received(), 75 ether);
        assertEq(e.fairOut(), 72 ether);
        assertEq(e.excess(), 3 ether);
        assertEq(e.leftForOther(), 45 ether);
    }

    function test_control() public {
        Exploit e = new Exploit();
        e.runControl();
    }
}
