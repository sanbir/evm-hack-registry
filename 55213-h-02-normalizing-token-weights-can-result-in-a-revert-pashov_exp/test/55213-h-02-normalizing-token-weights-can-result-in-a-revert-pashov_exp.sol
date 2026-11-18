// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./55213-h-02-normalizing-token-weights-can-result-in-a-revert-pashov.sol";

contract FindingTest is Test {
    function test_exploit() public {
        
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.swapReverted());
        assertEq(e.stuck(), 1000 ether);
        assertEq(e.controlPaid(), 1000 ether);
    }
}
