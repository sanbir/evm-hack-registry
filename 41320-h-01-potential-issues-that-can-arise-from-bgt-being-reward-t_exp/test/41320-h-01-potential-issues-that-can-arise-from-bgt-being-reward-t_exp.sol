// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AegisVaultFixed, BGT, ERC20, Exploit, RewardsVault} from "./41320-h-01-potential-issues-that-can-arise-from-bgt-being-reward-t.sol";

contract Finding41320Test is Test {
    function test_bgt_transfer_freezes_the_withdrawal() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vault().shares(address(e)), 1000 ether, "shares still locked");
        assertEq(e.asset().balanceOf(address(e.vault())), 1000 ether, "1000 assets frozen");
        assertEq(e.asset().balanceOf(address(e)), 0, "depositor got nothing");
        assertEq(e.bgt().balanceOf(e.farming()), 0, "BGT was not forwarded");
    }

    function test_control_skips_the_forward_when_the_vault_is_not_whitelisted() public {
        ERC20 asset = new ERC20("Vault Asset", "ASSET");
        BGT bgt = new BGT();
        RewardsVault rewards = new RewardsVault(bgt);
        address farming = address(0xF00D);
        AegisVaultFixed fixedVault = new AegisVaultFixed(asset, bgt, rewards, farming);
        bgt.setWhitelisted(address(rewards), true);
        bgt.mint(address(rewards), 50 ether);
        asset.mint(address(fixedVault), 1000 ether);
        fixedVault.seed(address(this), 1000 ether);
        fixedVault.withdraw(1000 ether);
        assertEq(asset.balanceOf(address(this)), 1000 ether, "withdrawal paid");
        assertEq(bgt.balanceOf(address(fixedVault)), 50 ether, "BGT stays in the vault instead of reverting");
        assertEq(fixedVault.shares(address(this)), 0, "shares burned");
    }
}
