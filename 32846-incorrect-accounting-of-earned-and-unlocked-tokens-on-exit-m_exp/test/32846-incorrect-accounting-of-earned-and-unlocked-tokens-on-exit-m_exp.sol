// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./32846-incorrect-accounting-of-earned-and-unlocked-tokens-on-exit-m.sol";

contract FindingTest is Test {
    function test_attack() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 100 ether);
        assertEq(e.frozen(), 50 ether);
        assertTrue(e.lockReverted());
        assertEq(e.staleUnlocked(), 40 ether);
        assertEq(e.staleEarned(), 60 ether);
    }

    function test_control() public {
        Exploit e = new Exploit();
        e.runControl();
    }
}
