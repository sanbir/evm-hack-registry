// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65329-global-mp-cap-invariant-can-be-broken-on-unstake-causing-ari.sol";

contract GlobalMpCapUnstakeDoSTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.invariantBroken(), "totalMPAccrued > totalMaxMP");
        assertTrue(e.dosDemonstrated(), "updateGlobalState reverts");
    }

    function test_control_healthy_update() public {
        StakeManager sm = new StakeManager();
        sm.seedVault(address(0xB), 100e18, 50e18, 100e18);
        sm.setGlobals(50e18, 100e18, 0);
        // accrued < max → update succeeds
        sm.updateGlobalState();
        assertLe(sm.totalMPAccrued(), sm.totalMaxMP());
    }
}
