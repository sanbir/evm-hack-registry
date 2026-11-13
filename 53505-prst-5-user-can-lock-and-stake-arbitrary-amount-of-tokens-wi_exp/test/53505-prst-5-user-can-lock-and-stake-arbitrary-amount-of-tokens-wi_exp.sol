// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./53505-prst-5-user-can-lock-and-stake-arbitrary-amount-of-tokens-wi.sol";

contract Finding53505Test is Test {
    function test_empty_funds_locks_100_and_stakes_alices_tokens() public {
        Exploit e = new Exploit();
        e.run();
        console2.log("stolen", e.stolen());
        assertEq(e.stolen(), 100 ether, "stolen");
        assertEq(e.lst().balanceOf(address(e)), 100 ether, "bob");
        assertEq(e.lst().balanceOf(address(e.locker())), 0, "empty");
    }

    function test_control_unpaid_lock_reverts_and_alice_keeps_100() public {
        Exploit e = new Exploit();
        e.runControl();
        console2.log("control kept", e.aliceStillLocked());
        assertTrue(e.controlReverted(), "reverted");
        assertEq(e.aliceStillLocked(), 100 ether, "kept");
        assertEq(e.lst().balanceOf(address(e)), 0, "bob");
    }
}
