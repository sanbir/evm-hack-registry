// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, CapitalPool, TokenManagerFixed} from
    "./38064-native-token-withdrawal-fails-until-manually-approved-codeha.sol";

contract Finding38064Test is Test {
    function test_exploit_wrong_approve_target_locks_maker_refund() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.withdrawReverted(), "reverted");
        assertEq(e.stuck(), 1000 ether, "stuck");
        assertEq(e.token().balanceOf(address(e)), 0, "user");
    }

    function test_control_approve_token_pays_the_refund() public {
        Token token = new Token();
        CapitalPool pool = new CapitalPool();
        TokenManagerFixed mgr = new TokenManagerFixed(token, pool);
        pool.setManager(address(mgr));
        token.mint(address(this), 1000 ether);
        token.approve(address(mgr), 1000 ether);
        mgr.credit(address(this), 1000 ether);
        mgr.withdraw(address(token));
        assertEq(token.balanceOf(address(this)), 1000 ether, "paid");
        assertEq(token.balanceOf(address(pool)), 0, "empty");
    }
}
