// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./58246-h-02-computationunitsavailable-can-overestimate-number-of-av.sol";
contract Finding58246Test is Test {
    function test_exploit_inflated_units_release_reward() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.realUnits(), 10, "real 10");
        assertEq(e.available(), 50, "reported 50");
        assertEq(e.rewardPaid(), 40e18, "40 reward");
        assertTrue(e.controlReverted(), "control should revert");
        assertEq(e.reward().balanceOf(address(e)), 40e18, "exploit received 40");
    }
}
