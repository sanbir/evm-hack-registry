// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    BookVuln,
    BookFixed,
    MiniToken
} from "./64869-h-01-order-double-linked-list-is-broken-because-orderprevord.sol";

// GTE CLOB — H-01: Order double-linked list is broken because order.prevOrderId
// is written to a MEMORY copy in Book._updateLimitPostOrder and never persisted
// to storage. Removing the tail order then corrupts the limit's head/tail
// pointers to null while a live order still occupies the limit → order-book DoS.
//
// Real source: github.com/code-423n4/2025-07-gte-clob @ 9f06332 (pre-fix).
contract OrderPrevIdNotPersistedTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_brokenBackpointer_dosesOrderBook() public {
        Exploit e = new Exploit();
        e.run();

        // ── Broken invariant A: order2 (the tail) lost its back-pointer ──
        // In the buggy book the write landed on a memory copy: storage prev == null.
        assertEq(e.buggyPrevOf2(), 0, "buggy: order2.prevOrderId must be null (not persisted)");
        // Sanity: the forward pointer (a storage write) DID persist.
        BookVuln bv = BookVuln(e.bookVulnAddr());
        assertEq(bv.getNextOrderId(1), 2, "buggy: order1.nextOrderId persisted (forward link OK)");

        // ── DoS B: removing the tail nulls BOTH limit pointers though order1 lives ──
        assertEq(e.buggyHeadAfterRemove(), 0, "buggy: limit.headOrder corrupted to null");
        assertEq(e.buggyTailAfterRemove(), 0, "buggy: limit.tailOrder corrupted to null");
        assertEq(uint256(e.buggyNumOrdersAfterRemove()), 1, "buggy: limit still claims 1 order");
        assertTrue(e.buggyOrder1Exists(), "buggy: order1 remains live but orphaned (unreachable)");

        // ── DoS magnitude recorded on the marker token at the SINK ──
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 1, "marker records 1 orphaned order at SINK");
        assertEq(e.sinkMarkerBalance(), 1, "exploit-reported sink balance matches");
    }

    function test_control_fixedPersistsBackpointer_listStaysConsistent() public {
        // The Exploit runs BOTH books; assert the fixed variant is NOT corrupted.
        Exploit e = new Exploit();
        e.run();

        // Fixed book persists the back-pointer...
        assertEq(e.fixedPrevOf2(), 1, "fixed: order2.prevOrderId persisted to order1");

        // ...and removing the tail correctly falls the limit back to order1.
        assertEq(e.fixedHeadAfterRemove(), 1, "fixed: limit.headOrder stays order1");
        assertEq(e.fixedTailAfterRemove(), 1, "fixed: limit.tailOrder falls back to order1");
        assertTrue(e.fixedOrder1Exists(), "fixed: order1 still reachable via limit");

        // The bug is causal: same scenario, only the memory-vs-storage param differs.
        assertTrue(e.buggyTailAfterRemove() == 0 && e.fixedTailAfterRemove() == 1, "harm caused by the bug, not the setup");

        BookFixed bf = BookFixed(e.bookFixedAddr());
        assertEq(bf.getAskTail(1000), 1, "fixed book tail readable on-chain == order1");
    }
}
