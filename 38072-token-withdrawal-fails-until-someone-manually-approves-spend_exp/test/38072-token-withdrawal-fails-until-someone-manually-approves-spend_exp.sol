// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20Mini, CapitalPool, TokenManagerFixed} from "./38072-token-withdrawal-fails-until-someone-manually-approves-spend.sol";

contract Finding38072Test is Test {
    function test_exploit_withdraw_reverts_until_allowance() public {
        Exploit e = new Exploit();
        e.run();
        assertFalse(e.withdrew(), "withdrew");
        assertTrue(e.stuck(), "not stuck");
        assertEq(e.token().balanceOf(address(e.pool())), 1_200_000 ether, "pool");
        assertEq(e.token().balanceOf(address(e.maker())), 0, "maker");
    }

    function test_control_approve_lets_withdraw_succeed() public {
        ERC20Mini token = new ERC20Mini();
        CapitalPool pool = new CapitalPool();
        TokenManagerFixed tm = new TokenManagerFixed(token, address(pool));
        token.mint(address(pool), 1_200_000 ether);
        tm.addTokenBalance(address(this), address(token), 4, 1_200_000 ether);
        tm.withdraw(address(token), 4);
        assertEq(token.balanceOf(address(this)), 1_200_000 ether, "received");
        assertEq(token.balanceOf(address(pool)), 0, "pool empty");
    }
}
