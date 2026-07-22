// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38182-newly-created-gauge-may-missed-out-on-its-rewards-immunefi-a.sol";

contract StaleMemoryVarDistributeTest is Test {
    /// @notice HARM: run() proves a newly-created gauge receives nothing on
    ///         its first distribute() despite claimable[gauge] storage being
    ///         correctly nonzero, and only gets paid on the second call.
    function test_exploit_firstDistributeMissesReward() public {
        Exploit e = new Exploit();
        e.run();

        assertGt(e.alcx().balanceOf(e.POOL()), 0, "gauge eventually receives its reward (on the second distribute)");
        assertEq(e.voter().claimable(e.gauge()), 0, "claimable storage is drained after the second (paying) distribute");
    }

    /// @notice Isolates the stale-memory-variable interaction directly: a
    ///         brand-new gauge's first _updateFor sync happens INSIDE the
    ///         same _distribute() call whose _claimable was already read.
    function test_buggyVoter_firstSyncAndFirstPayoutAreDifferentCalls() public {
        MockALCX alcx = new MockALCX();
        Voter voter = new Voter(alcx);
        address pool = address(0xBEEF);

        address gauge = voter.createGauge(pool);
        voter.vote(gauge, pool, 100);
        voter.notifyRewardAmount(1000 ether, 100);

        assertEq(voter.supplyIndex(gauge), 0, "gauge has never synced before its first distribute");

        voter.distribute(gauge);
        assertEq(alcx.balanceOf(pool), 0, "first distribute pays nothing");
        assertGt(voter.claimable(gauge), 0, "but claimable storage IS now nonzero");

        voter.distribute(gauge);
        assertGt(alcx.balanceOf(pool), 0, "second distribute finally pays out");
    }

    /// @notice Control: if claimable[gauge] is populated by an EXTERNAL
    ///         updateFor() call BEFORE distribute() ever runs, distribute()
    ///         correctly reads that already-nonzero storage value into
    ///         `_claimable` and pays it out on its first call -- isolating
    ///         that the bug is specifically "first sync and first payout
    ///         attempt happen inside the SAME _distribute() call", not
    ///         "distribute is broken in general".
    function test_control_externallyPreSyncedGaugePaysOutOnFirstDistribute() public {
        MockALCX alcx = new MockALCX();
        Voter voter = new Voter(alcx);
        address pool = address(0xBEEF);

        address gauge = voter.createGauge(pool);
        voter.vote(gauge, pool, 100);
        voter.notifyRewardAmount(1000 ether, 100);

        // Sync the gauge OUTSIDE of distribute() -- this writes a nonzero
        // claimable[gauge] to storage via a separate call.
        voter.updateFor(gauge);
        assertGt(voter.claimable(gauge), 0, "claimable is populated by the external sync");

        // Now distribute()'s `_claimable` read sees the ALREADY-populated
        // storage value (from the external sync above), so the first-ever
        // distribute() call pays out correctly.
        voter.distribute(gauge);
        assertGt(alcx.balanceOf(pool), 0, "pre-synced gauge pays out on its first distribute() call");
    }
}
