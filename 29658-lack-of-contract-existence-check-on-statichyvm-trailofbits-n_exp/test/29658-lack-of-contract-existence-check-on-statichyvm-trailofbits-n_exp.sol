// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./29658-lack-of-contract-existence-check-on-statichyvm-trailofbits-n.sol";

contract Finding29658Test is Test {
    function test_empty_hyvm_delegatecall_releases_vault() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 1_000 ether, "1000 released");
        assertEq(e.asset().balanceOf(address(e)), 1_000 ether, "attacker holds it");
        assertEq(e.asset().balanceOf(address(e.openVault())), 0, "open vault empty");
        assertTrue(e.controlReverted(), "codesize check reverted");
        assertEq(e.asset().balanceOf(address(e.guardedVault())), 1_000 ether, "control kept 1000");
        assertEq(e.hyvm().hyvm().code.length, 0, "no code");
        console2.log("stolen wei", e.stolen());
        console2.log("control vault wei", e.asset().balanceOf(address(e.guardedVault())));
    }
}
