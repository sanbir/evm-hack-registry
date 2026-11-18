// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./61406-c-04-memory-vs-storage-mismatch-renders-session-state-update.sol";

contract FindingTest is Test {
    function test_exploit() public {
        
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.stillLive());
        assertEq(e.pulled(), 1000 ether);
        assertTrue(e.controlBlocked());
    }
}
