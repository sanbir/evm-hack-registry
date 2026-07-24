// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./48701-abacus-past-closure-adjustment.sol";

contract Poc48701Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.attack();
        assertTrue(e.success(), "reduced model did not reproduce 48701");
    }
}

