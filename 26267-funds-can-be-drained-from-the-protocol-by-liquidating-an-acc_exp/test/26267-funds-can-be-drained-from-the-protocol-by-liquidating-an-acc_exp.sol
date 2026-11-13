// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./26267-funds-can-be-drained-from-the-protocol-by-liquidating-an-acc.sol";

contract FindingTest is Test {
    function test_drain() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.reserves(), e.N(), "reserves");
        assertTrue(e.hooked(), "hook");
        assertEq(e.cynthiaNet(), -int256(e.N()), "cynthia");
        assertEq(e.bobPulled(), e.N(), "bob");
        assertEq(e.victimLeft(), 0, "victim cash");
        assertTrue(e.victimBlocked(), "victim blocked");
        assertEq(e.cash().balanceOf(address(e)), e.N(), "attacker");
        assertEq(e.cash().balanceOf(e.VICTIM()), 0, "victim");
        assertTrue(e.controlReverted(), "control");
        assertEq(e.controlVictimGot(), e.N(), "control victim");
        console2.log("reserves");
        console2.log(e.reserves());
        console2.log("bob pulled");
        console2.log(e.bobPulled());
        console2.log("victim left");
        console2.log(e.victimLeft());
        console2.log("cynthia net abs");
        console2.log(uint256(-e.cynthiaNet()));
        console2.log("control victim got");
        console2.log(e.controlVictimGot());
    }
}
