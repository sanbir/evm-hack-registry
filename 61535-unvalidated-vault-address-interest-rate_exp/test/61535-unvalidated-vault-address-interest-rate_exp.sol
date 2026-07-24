// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./61535-unvalidated-vault-address-interest-rate.sol";

contract VaultAdapterRateTest is Test {
    function test_exploit_reproduces_audit_harm() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.confirmed(), "synthetic harm invariant not reached");
    }
}

