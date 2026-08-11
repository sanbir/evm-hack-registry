// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    CardAllocationPool,
    CardAllocationPoolFixed,
    Packet,
    MockVRFCoordinator,
    MiniToken,
    InsufficientCardBundles
} from "./62539-h-02-insufficient-restrictions-in-instantopenpacket-risk-dos.sol";

contract InstantOpenPacketDosTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER1 = 0x00000000000000000000000000000000000A1111;
    address internal constant USER2 = 0x00000000000000000000000000000000000B2222;

    uint256 internal constant PACKET_TYPE = 7;
    uint256 internal constant PACKET_ID_1 = 101;
    uint256 internal constant PACKET_ID_2 = 102;

    // ── EXPLOIT: TOCTOU DoS permanently locks user2's packet ───────────────────
    function test_exploit_secondFulfillmentReverts_locksUser2Packet() public {
        Exploit e = new Exploit();
        e.run();

        // One bundle existed; both requests passed the request-time check.
        assertEq(e.bundlesBefore(), 1, "exactly one bundle seeded");

        // user1 was served (bundle popped); user2's fulfillment reverted and is
        // never retried by VRF -> user2's packet is permanently stuck.
        assertTrue(e.user1Served(), "user1 served by first fulfillment");
        assertTrue(e.req2Reverted(), "second fulfillRandomWords reverted (DoS)");
        assertFalse(e.user2Fulfilled(), "user2 request remains permanently unfulfilled");
        assertEq(e.bundlesAfter(), 0, "the only bundle was consumed by user1");

        // Ground-truth on the real pool state.
        CardAllocationPool pool = CardAllocationPool(e.poolAddr());
        assertGt(pool.cardsDelivered(USER1), 0, "user1 received cards");
        assertEq(pool.cardsDelivered(USER2), 0, "user2 received nothing");
        assertEq(pool.fulfilledCount(), 1, "only one of two requests could ever be fulfilled");

        // Harm marker: 1 permanently locked Packet NFT recorded at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 1, "1 locked packet recorded at SINK");
        assertEq(e.sinkMarkerBalance(), 1, "exploit-reported sink balance");
    }

    // ── CONTROL: the fixed pool reserves at request time; user2 reverts up front ─
    function test_control_fixedReservesAtRequestTime_noStuckState() public {
        Packet packet = new Packet();
        MockVRFCoordinator coord = new MockVRFCoordinator();
        CardAllocationPoolFixed pool = new CardAllocationPoolFixed(address(coord), address(packet));

        coord.setConsumer(address(pool));
        packet.setPool(address(pool));
        packet.setPacketType(PACKET_ID_1, PACKET_TYPE);
        packet.setPacketType(PACKET_ID_2, PACKET_TYPE);

        uint256[] memory cardIds = new uint256[](3);
        cardIds[0] = 1;
        cardIds[1] = 2;
        cardIds[2] = 3;
        pool.addCardBundle(PACKET_TYPE, cardIds);

        // user1's request succeeds and reserves the only bundle.
        packet.initiateBurn(PACKET_ID_1, USER1);
        assertEq(pool.reservedCount(PACKET_TYPE), 1, "one bundle reserved");

        // user2's request now reverts UP FRONT — no VRF request is ever made,
        // so no post-fulfillment stuck state can exist.
        vm.expectRevert(InsufficientCardBundles.selector);
        packet.initiateBurn(PACKET_ID_2, USER2);

        // Only user1 has an in-flight request; fulfilling it serves user1 cleanly.
        uint256[] memory words = new uint256[](1);
        words[0] = 42;
        coord.fulfill(coord.requestIds(0), words);

        assertGt(pool.cardsDelivered(USER1), 0, "user1 served under fix");
        assertEq(pool.cardsDelivered(USER2), 0, "user2 never entered a stuck state");
        assertEq(pool.bundleCount(PACKET_TYPE), 0, "bundle consumed exactly once");
        assertEq(pool.reservedCount(PACKET_TYPE), 0, "reservation released after fulfillment");
    }
}
