// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58334-h-02-reward-token-in-gaugefactorycl-can-be-drained-by-anyone.sol";

contract BlackholeGaugeFactoryDrainTest is Test {
    function test_exploit_anyoneDrainsRewardViaCreateGauge() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.drained(), e.PREFUND(), "full drain");
        assertEq(e.factoryAfter(), 0, "factory empty");
        assertEq(e.farmingAfter(), e.PREFUND(), "rewards in farm");
        assertEq(e.factory().gaugeCount(), 5, "spam gauges");
    }
}
