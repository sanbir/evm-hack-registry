// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./53314-c-03-users-cant-redeem-funds-due-to-malicious-manipulation-o.sol";

contract FindingTest is Test {
    function test_exploit() public {
        
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.aliceReverted());
        assertEq(e.aliceStuck(), 20 ether);
        assertEq(e.bobReceived(), 40 ether);
        assertEq(e.controlAlicePaid(), 20 ether);
        assertEq(e.controlLeft(), 20 ether);
    }
}
