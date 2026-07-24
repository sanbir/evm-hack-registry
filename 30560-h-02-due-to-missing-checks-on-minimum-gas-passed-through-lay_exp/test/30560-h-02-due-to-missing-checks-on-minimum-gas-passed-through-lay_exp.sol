// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30560-h-02-due-to-missing-checks-on-minimum-gas-passed-through-lay.sol";

/* Decent H-02 — underfunded dst gas STORES message and blocks the LZ channel */
contract PoC_30560 is Test {
    function test_underfunded_gas_blocks_channel() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.endpoint().isBlocked(1, 2));
        assertEq(e.endpoint().storedCount(), 1);
        assertEq(e.destApp().executions(), 0);
    }

    function test_control_well_funded_succeeds_on_fresh_channel() public {
        MockLzEndpoint endpoint = new MockLzEndpoint();
        DestinationApp destApp = new DestinationApp();
        DecentEthRouter router = new DecentEthRouter(address(endpoint), address(destApp));

        // Fresh path, plenty of gas → SUCCESS, not blocked.
        bool ok = router.bridgeWithPayload(uint64(200_000), bytes("ok"));
        assertTrue(ok);
        assertFalse(endpoint.isBlocked(1, 2));
        assertEq(destApp.executions(), 1);
    }
}
