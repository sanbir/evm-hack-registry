// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, BunniHook} from "./43549-h-04-attacker-can-dos-the-rebalance-mechanism-pashov-audit-g.sol";
contract Finding43549Test is Test {
    function test_donation_bricks_rebalance() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.dos());
        assertFalse(e.hook().rebalanced());
        assertEq(e.token().balanceOf(address(e.hook())), 1);
    }
    function test_control_exact_amount_rebalances() public {
        Token t = new Token();
        BunniHook h = new BunniHook(t);
        t.mint(address(this), 1000e18);
        h.rebalanceOrderPreHook(1000e18);
        assertTrue(h.rebalanced());
        assertEq(t.balanceOf(address(h)), 1000e18);
    }
}
