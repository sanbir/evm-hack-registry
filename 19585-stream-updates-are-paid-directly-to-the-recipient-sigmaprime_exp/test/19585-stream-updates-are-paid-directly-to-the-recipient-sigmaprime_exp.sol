// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./19585-stream-updates-are-paid-directly-to-the-recipient-sigmaprime.sol";

contract FindingTest is Test {
    function test_exploit() public {
        
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 400 ether);
        assertEq(e.victimLeft(), 600 ether);
        assertEq(e.controlVictim(), 1000 ether);
    }
}
