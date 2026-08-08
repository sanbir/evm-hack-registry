// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, MerkleBase, MerkleBaseFixed, MiniToken} from "./60150-commitments-can-be-overwritten-by-overflowing-the-tree-qua.sol";

contract MerkleOverflowTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant DEPOSIT = 1e18;

    function test_exploit_overflow_overwrites_first_commitment() public {
        Exploit e = new Exploit();
        e.run();

        // The tree grew past its 16-leaf limit: m_index reaches 36 (16 + 20 inserts).
        assertEq(e.finalIndex(), 36, "tree should overflow past capacity to index 36");

        // Before overflow, slot MINIMUM_INDEX held the first depositor's commitment.
        assertEq(e.nodeBefore(), e.firstCommitment(), "first commitment must be intact when tree is full");

        // The overflow insert clobbered that same slot.
        assertTrue(e.overwritten(), "first commitment must be overwritten by the overflow");
        assertTrue(e.nodeAfter() != e.firstCommitment(), "slot no longer holds the first commitment");

        // Harm is quantified on the marker sink: one full deposit invalidated.
        MiniToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), DEPOSIT, "invalidated deposit magnitude sent to sink");
        assertEq(e.markerToSink(), DEPOSIT, "recorded harm magnitude");
    }

    function test_control_fixed_rejects_overflow() public {
        MerkleBaseFixed tree = new MerkleBaseFixed();

        // Fill the tree legitimately with all 16 leaves.
        bytes32[] memory fill16 = new bytes32[](16);
        for (uint256 i = 0; i < 16; i++) {
            fill16[i] = bytes32(DEPOSIT + i);
        }
        tree.insertMany(fill16);

        bytes32 firstCommitmentSlot = tree.nodes(tree.MINIMUM_INDEX());
        assertEq(firstCommitmentSlot, bytes32(DEPOSIT), "first commitment stored at MINIMUM_INDEX");
        assertEq(tree.m_index(), 32, "tree full at m_index == 2^LEVELS");

        // A single overflow insert must revert instead of overwriting a commitment.
        vm.expectRevert(bytes("Tree is full."));
        tree.insert(bytes32(DEPOSIT + 16));

        // A batch that would overflow must also revert via insertMany's capacity check.
        bytes32[] memory extra4 = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            extra4[i] = bytes32(DEPOSIT + 16 + i);
        }
        vm.expectRevert(bytes("Tree overflow"));
        tree.insertMany(extra4);

        // First commitment remains intact under the fix.
        assertEq(tree.nodes(tree.MINIMUM_INDEX()), bytes32(DEPOSIT), "first commitment preserved by the fix");
    }
}
