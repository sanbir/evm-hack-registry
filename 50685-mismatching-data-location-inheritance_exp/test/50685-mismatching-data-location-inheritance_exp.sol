// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./50685-mismatching-data-location-inheritance.sol";

contract Poc50685Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.attack();
        assertTrue(e.success(), "reduced model did not reproduce 50685");
    }
}
