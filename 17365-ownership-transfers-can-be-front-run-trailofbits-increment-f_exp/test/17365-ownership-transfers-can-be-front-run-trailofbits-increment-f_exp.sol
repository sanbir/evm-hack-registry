// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit} from
    "./17365-ownership-transfers-can-be-front-run-trailofbits-increment-f.sol";

contract Finding17365Test is Test {
    function test_exploit_eve_claims_perp_and_pulls_1000() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.book().perp(), address(e.eve()), "eve is perp");
        assertEq(e.token().balanceOf(e.ATTACKER()), 1000 ether, "attacker pulled 1000");
        assertEq(e.token().balanceOf(address(e.book())), 0, "reserves emptied");

        console2.log("pulled", e.token().balanceOf(e.ATTACKER()));
        console2.log("perp is eve", e.book().perp() == address(e.eve()) ? 1 : 0);
    }

    function test_control_two_step_blocks_eve_and_pays_treasury() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertEq(c.book().perp(), address(c.market()), "market completed the two-step");
        assertEq(c.token().balanceOf(c.ATTACKER()), 0, "attacker received nothing");
        assertEq(c.token().balanceOf(c.TREASURY()), 1000 ether, "treasury received 1000");
        assertEq(c.token().balanceOf(address(c.book())), 0, "reserves left the book with the nominee");

        console2.log("control treasury", c.token().balanceOf(c.TREASURY()));
        console2.log("control attacker", c.token().balanceOf(c.ATTACKER()));
    }
}
