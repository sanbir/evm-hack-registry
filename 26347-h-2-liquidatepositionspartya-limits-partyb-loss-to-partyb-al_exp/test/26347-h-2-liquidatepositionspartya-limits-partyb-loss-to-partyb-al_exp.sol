// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./26347-h-2-liquidatepositionspartya-limits-partyb-loss-to-partyb-al.sol";

contract FindingTest is Test {
    function test_inflated_balance() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.deducted(), 0, "deducted");
        assertEq(e.inflated(), int256(e.GAIN()), "inflated");
        assertEq(e.pulled(), e.GAIN(), "pulled");
        assertEq(e.leftForOthers(), 0, "others");
        assertEq(e.fairAllocated(), int256(e.FAIR()), "fair");
        assertEq(e.controlPulled(), e.FAIR(), "control pulled");
        assertEq(e.controlLeft(), e.GAIN() - e.FAIR(), "control left");
        assertEq(e.pulled() - e.controlPulled(), e.LOSS(), "extra");
        console2.log("deducted");
        console2.log(e.deducted());
        console2.log("inflated");
        console2.log(uint256(e.inflated()));
        console2.log("pulled");
        console2.log(e.pulled());
        console2.log("fair");
        console2.log(uint256(e.fairAllocated()));
        console2.log("control left");
        console2.log(e.controlLeft());
        console2.log("extra");
        console2.log(e.pulled() - e.controlPulled());
    }
}
