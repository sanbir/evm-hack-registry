// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    ERC20Airdrop2Fixed,
    Exploit,
    MockTKO,
    Vault
} from "./31931-h-03-users-will-never-be-able-to-withdraw-their-claimed-aird.sol";

contract Finding31931Test is Test {
    uint256 internal constant AMOUNT = 100 ether;
    uint64 internal constant CLAIM_END = 1000;
    uint64 internal constant WINDOW = 1000;
    uint256 internal constant NOW = 1_000_000;

    function setUp() public {
        vm.warp(NOW);
    }

    function test_exploit_full_claim_stuck_after_window() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.withdrawReverted(), "withdraw reverted");
        assertEq(e.stuck(), AMOUNT, "100 TKO seated");
        assertEq(e.userReceived(), 0, "user received 0");
        assertEq(e.tko().balanceOf(address(e.vault())), AMOUNT, "100 TKO stuck in the vault");
        assertEq(e.tko().balanceOf(address(e)), 0, "user balance");
        assertTrue(e.airdrop().windowClosed(), "now is past the window");
        assertGt(NOW, uint256(CLAIM_END) + WINDOW, "block is after full unlock");
    }

    function test_control_buffer_pays_the_user() public {
        MockTKO tko = new MockTKO();
        Vault vault = new Vault();
        ERC20Airdrop2Fixed drop = new ERC20Airdrop2Fixed(address(tko), address(vault), CLAIM_END, WINDOW);

        tko.mint(address(vault), AMOUNT);
        vault.approve(address(tko), address(drop), AMOUNT);
        drop.seedClaim(address(this), AMOUNT);
        assertTrue(drop.windowClosed(), "same closed window");

        drop.withdraw(address(this));

        assertEq(tko.balanceOf(address(this)), AMOUNT, "user receives 100 TKO");
        assertEq(tko.balanceOf(address(vault)), 0, "vault emptied");
    }
}
