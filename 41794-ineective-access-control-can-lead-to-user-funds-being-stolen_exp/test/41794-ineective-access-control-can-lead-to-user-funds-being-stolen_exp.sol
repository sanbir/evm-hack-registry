// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./41794-ineective-access-control-can-lead-to-user-funds-being-stolen.sol";

contract FindingTest is Test {
    function test_exploit() public {
        
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 100_000 ether);
        assertTrue(e.foreignBlocked());
        assertTrue(e.fixedBlocked());
    }
}
