// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    AccountableAsyncRedeemVault,
    AccountableAsyncRedeemVaultFixed,
    AsyncStrategy,
    SyncStrategy,
    IRedeemStrategy,
    MiniToken
} from "./62970-critical-dos-in-queue-processing-if-async-cancellations-are.sol";

contract AsyncCancelQueueDosTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER_A = 0x000000000000000000000000000000000000aaaa;
    address internal constant USER_B = 0x000000000000000000000000000000000000BbBB;

    uint256 internal constant A_SHARES = 50 ether;
    uint256 internal constant B_SHARES = 100 ether;

    // ── Exploit: an async-pending cancel bricks the whole redemption queue ──
    function test_exploit_asyncCancelBricksQueue() public {
        Exploit e = new Exploit();
        e.run();

        // The queue processor reverted (DoS confirmed cheatcode-free inside run()).
        assertTrue(e.dosConfirmed(), "processUpToShares should revert (DoS)");

        // B's legitimate redemption is frozen — its shares still sit in the queue.
        assertEq(e.bPendingAfter(), B_SHARES, "B's redemption frozen in queue");

        // Every queued share (A's cancelled-but-stuck + B's) is frozen.
        assertEq(e.frozenShares(), A_SHARES + B_SHARES, "all queued shares frozen");

        // Marker records the frozen magnitude at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), A_SHARES + B_SHARES, "marker records frozen shares at SINK");

        // Permanence: the head never advanced, and re-calling processing still reverts.
        AccountableAsyncRedeemVault v = AccountableAsyncRedeemVault(e.vaultAddr());
        assertEq(v.nextRequestId(), 1, "queue head stuck at the cancelled request");
        vm.expectRevert(AccountableAsyncRedeemVault.RedeemRequestWasCancelled.selector);
        v.processUpToShares(type(uint256).max);
    }

    // ── Negative control #1: with NO pending cancel, the queue drains cleanly ──
    function test_control_noCancel_drainsQueue() public {
        AsyncStrategy strat = new AsyncStrategy();
        AccountableAsyncRedeemVault v = new AccountableAsyncRedeemVault(strat);

        v.requestRedeem(A_SHARES, USER_A);
        v.requestRedeem(B_SHARES, USER_B);

        // No cancel -> processing succeeds and empties the queue.
        v.processUpToShares(type(uint256).max);

        assertEq(v.pendingRedeemRequest(USER_A), 0, "A processed");
        assertEq(v.pendingRedeemRequest(USER_B), 0, "B processed");
        assertEq(v.nextRequestId(), v.lastRequestId(), "queue fully drained");
    }

    // ── Negative control #2: the FIXED vault (async removed) cancels without DoS ──
    function test_control_fixedVault_cancelDoesNotDos() public {
        SyncStrategy strat = new SyncStrategy();
        AccountableAsyncRedeemVaultFixed v = new AccountableAsyncRedeemVaultFixed(strat);

        v.requestRedeem(A_SHARES, USER_A);
        v.requestRedeem(B_SHARES, USER_B);

        // A cancels: the fixed vault fulfils it synchronously -> shares reduced, request dropped.
        v.cancelRedeemRequest(1, USER_A);
        assertEq(v.pendingRedeemRequest(USER_A), 0, "A cancel fully reduced under fix");
        assertFalse(v.pendingCancelRedeemRequest(USER_A), "no lingering pending cancel under fix");

        // Processing now drains B without reverting.
        v.processUpToShares(type(uint256).max);
        assertEq(v.pendingRedeemRequest(USER_B), 0, "B processed after fix");
        assertEq(v.nextRequestId(), v.lastRequestId(), "queue drained under fix");
    }
}
