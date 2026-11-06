// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    Vault,
    Context
} from "./24303-h-5-vaultsol-settleing-the-0-address-will-disrupt-accounting.sol";

/// Control: perennial-v2#86. Skip the local store when the account is address(0)
/// and write the global account last, so processGlobal's full keeper deduction sticks.
contract VaultFixed is Vault {
    constructor(address asset_) Vault(asset_) {}

    function _saveContext(Context memory context, address account) internal override {
        if (account != address(0)) _accounts[account] = context.local;
        _accounts[address(0)] = context.global;
        _checkpoints[context.currentId] = context.currentCheckpoint;
    }
}

contract Finding24303Test is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function test_exploit_zero_settle_inflates_assets_and_locks_funds() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.assetsAfterZeroSettle(), 780, "global assets 780 instead of 760");
        assertEq(e.asset().balanceOf(ALICE), 970, "alice paid 970 for 1000 shares");
        assertEq(e.asset().balanceOf(BOB), 970, "bob paid 970 for 1000 shares");
        assertEq(e.asset().balanceOf(address(e.vault())), 20, "20 USD locked");
        assertEq(e.lockedAssets(), 20, "locked witness");
        assertEq(e.asset().balanceOf(e.vault().KEEPER()), 40, "keeper was paid the real fee");
        assertEq(e.vault().globalAssets(), 20, "phantom claimable remains");
    }

    function test_control_zero_settle_does_not_change_honest_balances() public {
        Asset asset = new Asset();
        VaultFixed vault = new VaultFixed(address(asset));
        asset.mint(ALICE, 1000);
        asset.mint(BOB, 1000);
        vault.seed(ALICE, 1000);
        vault.seed(BOB, 1000);

        vault.advance();
        vault.redeem(ALICE, 400);
        vault.redeem(BOB, 400);
        vault.markSettled(40);
        vault.settle(address(0));
        assertEq(vault.globalAssets(), 760, "full keeper fee stays deducted");
        assertEq(vault.globalShares(), 1200, "shares unchanged");

        vault.settle(ALICE);
        vault.settle(BOB);
        assertEq(vault.assetsOf(ALICE), 380, "alice local claim");
        assertEq(vault.assetsOf(BOB), 380, "bob local claim");
        vault.claim(ALICE, 380);
        vault.claim(BOB, 380);
        assertEq(vault.globalAssets(), 0, "no phantom claimable");

        vault.advance();
        vault.redeem(ALICE, 600);
        vault.redeem(BOB, 600);
        vault.markSettled(0);
        vault.settle(ALICE);
        vault.settle(BOB);
        assertEq(vault.assetsOf(ALICE), 600, "alice exits at par");
        assertEq(vault.assetsOf(BOB), 600, "bob exits at par");
        vault.claim(ALICE, 600);
        vault.claim(BOB, 600);

        assertEq(asset.balanceOf(ALICE), 980, "alice received 1000 minus her 20 keeper");
        assertEq(asset.balanceOf(BOB), 980, "bob received 1000 minus his 20 keeper");
        assertEq(asset.balanceOf(address(vault)), 0, "nothing locked");
        assertEq(asset.balanceOf(vault.KEEPER()), 40, "same keeper fee");
    }
}
