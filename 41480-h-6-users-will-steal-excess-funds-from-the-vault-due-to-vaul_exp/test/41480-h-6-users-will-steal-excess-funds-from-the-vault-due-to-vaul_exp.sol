// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC20, Exploit, VaultFixed} from "./41480-h-6-users-will-steal-excess-funds-from-the-vault-due-to-vaul.sol";

contract Finding41480Test is Test {
    function test_stale_withdrawal_pool_pays_the_next_deposit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.ra().balanceOf(address(e)), 2000 ether, "attacker extracted 2000 RA");
        assertEq(e.ra().balanceOf(address(e.victim())), 0, "victim lost the new deposit");
        assertEq(e.ra().balanceOf(address(e.vault())), 0, "vault insolvent");
        (uint256 raBal, uint256 paBal,,) = e.vault().withdrawalPool();
        assertEq(raBal, 1000 ether, "raBalance never decreased");
        assertEq(paBal, 1000 ether, "paBalance never decreased");
    }

    function test_control_debiting_the_pool_leaves_the_deposit() public {
        ERC20 ra = new ERC20("Reserve Asset", "RA");
        VaultFixed vault = new VaultFixed(ra);
        ra.mint(address(vault), 1000 ether);
        ra.mint(address(this), 1000 ether);
        uint256 paid = vault.redeemExpired(1000 ether);
        assertEq(paid, 400 ether, "only the requested slice is paid");
        (uint256 raBal,,,) = vault.withdrawalPool();
        assertEq(raBal, 600 ether, "withdrawal pool was debited");
        assertEq(ra.balanceOf(address(vault)), 600 ether, "only 400 RA left the vault");
        assertEq(ra.balanceOf(address(this)), 1400 ether, "caller keeps the 1000 and receives only the 400 eligible");
    }
}
