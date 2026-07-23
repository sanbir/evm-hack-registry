// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63148-c-01-missing-delegatecall-check-pashov-audit-group-none-bico.sol";

contract BiconomyMissingDelegatecallTest is Test {
    function test_exploit_directCallCorruptsStorage() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(uint256(e.valueAfter()), 420, "slot written to 420");
        assertEq(uint256(e.valueBefore()), 0, "was empty");
    }

    function test_control_guardWouldBlockDirectCall() public {
        // With the recommended FIX, direct call reverts when THIS_ADDRESS == address(this).
        ComposableExecutionModule m = new ComposableExecutionModule();
        assertEq(m.thisAddress(), address(m), "module identity");
        // Simulate fixed guard:
        bool blocked = (m.thisAddress() == address(m));
        assertTrue(blocked, "direct call must be NotAllowed under fix");
    }
}
