// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./34260-funds-may-freeze-on-the-timelock-if-the-beneficiary-does-not.sol";

contract FindingTest is Test {
    function test_attack() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.claimReverted());
        assertEq(e.frozen(), 100 ether);
        assertEq(e.token().balanceOf(address(e.sink())), 0);
    }

    function test_control() public {
        Exploit e = new Exploit();
        e.runControl();
    }
}
