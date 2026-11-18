// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./66157-c-03-incorrect-boost-application-leads-to-inflated-rewards-i.sol";

contract FindingTest is Test {
    function test_exploit() public {
        
        Exploit e = new Exploit();
        e.run();
        assertEq(e.alicePaid(), 20_000);
        assertEq(e.controlPaid(), 200 ether);
    }
}
