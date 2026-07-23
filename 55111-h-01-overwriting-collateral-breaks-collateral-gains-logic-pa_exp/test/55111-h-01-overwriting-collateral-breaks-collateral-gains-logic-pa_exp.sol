// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./55111-h-01-overwriting-collateral-breaks-collateral-gains-logic-pa.sol";

contract OverwriteCollateralGainsTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.aliceCollCAfter(), 50e18, "alice claimed collA leftover as collC");
        assertTrue(e.bobClaimFailed(), "bob cannot claim drained pool");
        assertEq(e.leftoverGainCarried(), 50e18, "pending gain survived overwrite");
    }
}
