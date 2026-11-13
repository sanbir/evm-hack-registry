// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Token, Hook, Handler, NexusAccountFixed} from
    "./43809-fallback-logic-prevents-hooks-postcheck-from-getting-execute.sol";

contract Finding43809Test is Test {
    function test_exploit_fallback_return_skips_postcheck_and_drains() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 100 ether, "drained");
        assertEq(e.token().balanceOf(address(e)), 100 ether, "exploit");
        assertEq(e.token().balanceOf(address(e.account())), 0, "account empty");
        assertTrue(e.hook().preRan(), "pre");
        assertFalse(e.hook().postRan(), "post");
    }

    function test_control_postcheck_reverts_and_tokens_stay() public {
        Token token = new Token();
        Hook hook = new Hook(token);
        Handler handler = new Handler(token, address(this));
        NexusAccountFixed account = new NexusAccountFixed(address(hook), address(handler), token);
        token.mint(address(account), 100 ether);

        (bool ok,) = address(account).call("");
        assertFalse(ok, "postCheck reverts the drain");
        assertEq(token.balanceOf(address(account)), 100 ether, "still on the account");
        assertEq(token.balanceOf(address(this)), 0, "caller got nothing");
    }
}
