// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    Packet,
    PacketFixed,
    PacketBase,
    PacketStore,
    MarkerToken
} from "./62595-h-02-packet-burn-state-not-reset-in-finalizeopen-causes-fail.sol";

contract PacketBurnStateNotResetTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant OTHER = address(uint160(0xB0B));
    uint256 internal constant PACKET_ID = 1;

    function test_exploit_instantOpenFinalizeReverts_packetPermanentlyFrozen() public {
        Exploit e = new Exploit();
        e.run();

        // HARM: finalizeOpen() reverts because the burn state was never reset,
        // so the mandatory safeTransferFrom into inventory trips the freeze guard.
        assertTrue(e.finalizeReverted(), "finalizeOpen should revert (PacketFrozen)");

        // The open never completes: packet is still owned by the user and still
        // in the INSTANT_OPEN_PACKET (frozen) state.
        assertEq(e.packetOwnerAfter(), address(e), "packet still owned by user (open never finalized)");
        assertEq(
            e.burnTypeAfter(),
            uint256(PacketBase.BurnType.INSTANT_OPEN_PACKET),
            "burn state never reset to NONE"
        );

        // Permanently non-transferable: even the owner cannot move it afterwards.
        assertTrue(e.stillFrozen(), "packet is permanently non-transferable (any transferFrom reverts)");

        // Harm magnitude recorded at the SINK: 1 frozen packet NFT.
        assertEq(e.sinkMarkerBalance(), 1, "one packet permanently frozen");
        MarkerToken marker = MarkerToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 1, "marker records the frozen packet at SINK");

        // NEGATIVE CONTROL (embedded in run): the fixed variant resets the burn
        // state, so the identical finalize path succeeds and the packet leaves the
        // frozen state and moves into the store's inventory.
        assertTrue(e.fixedFinalizeSucceeded(), "fixed finalizeOpen succeeds");
        assertEq(e.fixedBurnTypeAfter(), uint256(PacketBase.BurnType.NONE), "fixed resets burn state to NONE");
        assertEq(e.fixedInventoryOwner(), e.storeAddr(), "fixed moves packet into store inventory");
    }

    // Direct negative control: reconstruct the scenario against the FIXED Packet
    // and show the instant-open finalize completes without freezing.
    function test_control_fixedPacket_finalizeOpenSucceeds() public {
        PacketStore store = new PacketStore();
        PacketFixed pkt = new PacketFixed(address(store));

        pkt.mint(address(this), PACKET_ID);
        pkt.initiateBurn(PACKET_ID, PacketBase.BurnType.INSTANT_OPEN_PACKET);

        // Succeeds (no revert): the fix resets the burn state before transfer.
        pkt.finalizeOpen(PACKET_ID);

        assertEq(pkt.burnTypeOf(PACKET_ID), uint256(PacketBase.BurnType.NONE), "burn state reset");
        assertEq(pkt.ownerOf(PACKET_ID), address(store), "packet moved into inventory");
    }

    // Show the same vulnerable Packet DOES work for a NONE-type packet: the bug
    // is specific to the missing INSTANT_OPEN_PACKET reset, not a broken transfer.
    function test_control_vulnerablePacket_nonFrozenTransferWorks() public {
        PacketStore store = new PacketStore();
        Packet pkt = new Packet(address(store));

        pkt.mint(address(this), PACKET_ID);
        // No initiateBurn → burn state is NONE → transfer is allowed.
        pkt.transferFrom(address(this), OTHER, PACKET_ID);
        assertEq(pkt.ownerOf(PACKET_ID), OTHER, "non-frozen packet transfers normally");
    }
}
