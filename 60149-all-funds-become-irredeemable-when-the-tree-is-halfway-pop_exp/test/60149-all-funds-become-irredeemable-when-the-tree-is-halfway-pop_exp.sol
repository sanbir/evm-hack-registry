// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, MiniMerkleBuggy, MiniMerkleFixed} from "./60149-all-funds-become-irredeemable-when-the-tree-is-halfway-pop.sol";

contract Hinkal60149Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant TRUE_ROOT_LEVEL = 4;

    function test_exploit_funds_irredeemable_when_tree_half_full() public {
        Exploit e = new Exploit();
        e.run();

        // HARM 1: the root the protocol must publish for the >half-full tree was
        // never written -> it is ZERO (finding's literal "tree[4] == 0").
        assertEq(e.publishedRoot(), 0, "published root should be 0 (bug: top root never stored)");
        assertTrue(e.allFundsLocked(), "all funds must be locked");

        // HARM 2: the sub-root the loop *did* touch is frozen (non-zero, stale) -
        // it no longer reflects the post-halfway commitments.
        assertTrue(e.frozenSubRoot() != 0, "sub-root should be non-zero (stale, frozen)");

        // HARM 3: 10 deposits of 1 ether are permanently irredeemable.
        uint256 expectedLocked = 10 ether;
        assertEq(e.totalLocked(), expectedLocked, "total locked must equal all deposits");

        // Cross-check against an INDEPENDENT correct tree: the real root over the
        // same 10 commitments is non-zero, proving the buggy zero is a defect and
        // that these funds *should* have been redeemable.
        MiniMerkleFixed fixedTree = new MiniMerkleFixed();
        for (uint256 i = 0; i < 10; i++) {
            fixedTree.insert(uint256(keccak256(abi.encode("commitment", i + 1))));
        }
        assertTrue(fixedTree.tree(TRUE_ROOT_LEVEL) != 0, "correct root must be non-zero");
        assertTrue(
            fixedTree.tree(TRUE_ROOT_LEVEL) != e.publishedRoot(),
            "buggy published root diverges from the correct root"
        );

        emit log_named_uint("locked wei (irredeemable)", e.totalLocked());
        emit log_named_uint("buggy published root (level 4)", e.publishedRoot());
        emit log_named_uint("correct root (level 4)", fixedTree.tree(TRUE_ROOT_LEVEL));
    }

    function test_control_fixed_tree_keeps_funds_redeemable() public {
        // Fixed variant persists the top root even when the tree is >half full.
        MiniMerkleFixed fixedTree = new MiniMerkleFixed();
        for (uint256 i = 0; i < 10; i++) {
            fixedTree.insert(uint256(keccak256(abi.encode("commitment", i + 1))));
        }

        // SAFE: the published root at the true root level is non-zero, so every
        // commitment (including the post-halfway ones) is provable/redeemable.
        assertTrue(fixedTree.tree(TRUE_ROOT_LEVEL) != 0, "fixed: root must be published (non-zero)");
        assertEq(fixedTree.leafCount(), 10, "fixed: all leaves inserted");

        // And it keeps updating as new leaves cross halfway (not frozen).
        uint256 rootBefore = fixedTree.tree(TRUE_ROOT_LEVEL);
        fixedTree.insert(uint256(keccak256(abi.encode("commitment", uint256(99)))));
        assertTrue(fixedTree.tree(TRUE_ROOT_LEVEL) != rootBefore, "fixed: root updates on new commitment");
    }
}
