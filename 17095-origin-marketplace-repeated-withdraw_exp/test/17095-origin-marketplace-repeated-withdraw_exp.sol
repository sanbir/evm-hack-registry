// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./17095-origin-marketplace-repeated-withdraw.sol";

contract RepeatedListingWithdrawTest is Test {
    function test_exploit_reproduces_audit_harm() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.confirmed(), "synthetic harm invariant not reached");
    }
}

