// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, CurveVault, LendingPoolFixed} from
    "./57202-ownership-parameter-mismatch-in-lendingpools-vault-withdrawa.sol";

contract Finding57202Test is Test {
    function test_exploit_msg_sender_owner_locks_vault_liquidity() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.withdrawReverted(), "reverted");
        assertEq(e.stuck(), 100 ether, "stuck");
        assertEq(e.token().balanceOf(address(e)), 0, "user");
        assertEq(e.vault().sharesOf(address(e.pool())), 100 ether, "shares");
    }

    function test_control_address_this_owner_returns_liquidity() public {
        Token token = new Token();
        CurveVault vault = new CurveVault(token);
        LendingPoolFixed pool = new LendingPoolFixed(token, vault);
        token.mint(address(this), 100 ether);
        token.approve(address(pool), 100 ether);
        pool.deposit(100 ether);
        pool.withdraw(100 ether);
        assertEq(token.balanceOf(address(this)), 100 ether, "paid");
        assertEq(token.balanceOf(address(vault)), 0, "empty");
        assertEq(vault.sharesOf(address(pool)), 0, "shares");
    }
}
