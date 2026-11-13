// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, WSHIDOFixed} from "./35628-insufficient-src-validation-allows-malicious-users-to-steal.sol";

contract Finding35628Test is Test {
    function test_exploit_steals_with_zero_allowance() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.allowanceBefore(), 0, "allowance was zero");
        assertEq(e.taken(), e.STEAL(), "attacker received 1000 WSHIDO");
        assertEq(e.victimAfter(), 0, "victim balance is gone");
    }

    function test_control_zero_allowance_reverts() public {
        WSHIDOFixed token = new WSHIDOFixed();
        address victim = address(0x3333);
        token.mint(victim, 1000 ether);
        vm.expectRevert(bytes("allowance"));
        token.transferFrom(victim, address(this), 1000 ether);
        assertEq(token.balanceOf(victim), 1000 ether, "victim keeps the tokens");
        assertEq(token.balanceOf(address(this)), 0, "attacker receives nothing");
    }
}
