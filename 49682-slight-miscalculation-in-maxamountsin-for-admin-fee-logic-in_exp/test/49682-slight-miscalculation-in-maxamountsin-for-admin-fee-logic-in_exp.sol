// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, Vault, UpliftOnlyExampleFixed} from
    "./49682-slight-miscalculation-in-maxamountsin-for-admin-fee-logic-in.sol";

contract Finding49682Test is Test {
    function test_exploit_admin_fee_rounds_remove_into_a_full_lock() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.amountInRaw(), e.maxIn() + 1, "one wei over max");
        assertFalse(e.removed(), "remove reverted");
        assertEq(e.token().balanceOf(address(e.vault())), 1000 ether, "1000 locked");
        assertEq(e.token().balanceOf(e.USER()), 0, "user received 0");
    }

    function test_control_one_wei_buffer_lets_the_user_exit() public {
        Token token = new Token();
        address pool = address(uint160(0xB001));
        Vault vault = new Vault(token, pool, address(uint160(0xAD11)));
        UpliftOnlyExampleFixed hook = new UpliftOnlyExampleFixed(vault, token, pool);
        address user = address(uint160(0xA11CE));
        token.mint(address(vault), 1000 ether);
        uint256 paid = hook.removeLiquidity(user, 1000 ether);

        assertEq(paid, 1000 ether - 2, "user exits");
        assertEq(token.balanceOf(user), 1000 ether - 2, "user balance");
        assertEq(token.balanceOf(address(vault)), 2, "only the fee remains");
    }
}
