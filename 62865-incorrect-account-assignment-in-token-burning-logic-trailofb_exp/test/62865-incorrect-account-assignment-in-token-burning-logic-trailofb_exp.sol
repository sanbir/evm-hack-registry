// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    AuthTokenFixed,
    Exploit
} from "./62865-incorrect-account-assignment-in-token-burning-logic-trailofb.sol";

contract Finding62865Test is Test {
    function test_exploit_burn_does_not_reduce_the_holder() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.kept(), 100 ether, "holder still has N");
        assertFalse(e.burnSucceeded(), "burn reverted");
        assertEq(e.token().balanceOf(address(e)), 100 ether, "balance not reduced");
        assertEq(e.token().burned(), 0, "zero address had nothing to burn");
        assertEq(e.token().balanceOf(address(0)), 0, "zero address unchanged");
    }

    function test_control_burns_the_caller() public {
        AuthTokenFixed token = new AuthTokenFixed();
        token.mint(address(this), 100 ether);
        token.update(address(this), address(0), 100 ether);

        assertEq(token.balanceOf(address(this)), 0, "caller was burned");
        assertEq(token.burned(), 100 ether, "N was debited from the caller");
    }
}
