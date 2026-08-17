// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, ValidatorManager, StakingL1, HYPE, StuckMarker} from "./58609-h-01-addrebalancerequest-may-use-outdated-balance-for-deleg.sol";

// Kinetiq H-01 (finding 58609): ValidatorManager._addRebalanceRequest persists a
// fixed withdrawal amount validated against the balance at request time.
// closeRebalanceRequest reuses that stale amount and never re-reads the live
// balance, so rewards accruing between request and close (100e18 -> 110e18) stay
// stuck: a full-deactivation close retrieves only 100e18, leaving 10e18 stranded.
contract Finding58609Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_staleRebalanceAmount_leavesFundsStuck() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("retrieved on close", e.retrieved());
        emit log_named_uint("stuck in validator", e.stuck());

        assertEq(e.retrieved(), 100 ether, "close used the stale stored amount (100e18)");
        assertEq(e.stuck(), 10 ether, "10e18 of rewards left stuck in validator");
        assertGt(e.stuck(), 0, "funds remain stranded despite full deactivation");
        assertEq(e.marker().balanceOf(SINK), 10 ether, "harm magnitude recorded to sink");
    }
}
