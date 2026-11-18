// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./45673-final-prices-within-a-threshold-of-10-minutes-are-accepted-l.sol";

contract FindingTest is Test {
    function test_exploit() public {
        
        Exploit e = new Exploit();
        e.run();
        assertEq(e.downPaid(), 200 ether);
        assertEq(e.controlUpPaid(), 200 ether);
    }
}
