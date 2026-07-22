// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27465-flag-can-be-overriden-by-another-user-codehawks-dittoeth-git.sol";

contract DittoFlagOverrideTest is Test {
    function test_FlagCanBeOverriddenByAnotherUser() public {
        Exploit e = new Exploit();
        e.run();

        assertFalse(e.flagger1LiquidateSucceeded());
        assertTrue(e.flagger2LiquidateSucceeded());
        assertEq(e.flagger2Reward(), 100);
    }

    /// @dev Control: BEFORE FIRST_LIQUIDATION_TIME has elapsed, the reuse
    ///      attempt correctly falls through to minting a FRESH flaggerId
    ///      instead of hijacking the existing one — proving the bug is
    ///      specifically the wrong threshold, not that the reuse check is
    ///      missing entirely.
    function test_Control_BeforeThreshold_NoHijack() public {
        MockToken token = new MockToken();
        MarginCallManager mgr = new MarginCallManager(token);
        Actor flagger1 = new Actor(mgr);
        Actor flagger2 = new Actor(mgr);
        token.mint(address(mgr), 1000);

        flagger1.flagShort(1, 0);
        (uint256 short1FlaggerId) = mgr.shortRecords(1);

        mgr.__test_advanceTime(5); // well before FIRST_LIQUIDATION_TIME (10)
        flagger2.flagShort(2, uint16(short1FlaggerId));

        // flagger1 still holds short1's flaggerId slot - no hijack yet.
        assertEq(mgr.getFlagger(short1FlaggerId), address(flagger1));
        (bool ok,) = flagger1.tryLiquidate(1);
        assertTrue(ok, "flagger1 should still be able to liquidate his own flagged short");
    }
}
