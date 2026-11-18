// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./41701-h-01-user-could-withdraw-more-than-supposed-to-forcing-last.sol";

contract Finding41701Test is Test {
    function test_exploit_last_lender_cannot_withdraw() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.aliceGot(), 300 ether, "alice");
        assertEq(e.bobGot(), 8, "bob");
        assertTrue(e.laurenceReverted(), "reverted");
        assertEq(e.token().balanceOf(e.LAURENCE()), 0, "laurence");
        assertEq(e.stuck(), 3 ether - 3, "stuck");
        assertEq(e.market().scaledBalance(e.LAURENCE()), 0, "burned");
    }
}
