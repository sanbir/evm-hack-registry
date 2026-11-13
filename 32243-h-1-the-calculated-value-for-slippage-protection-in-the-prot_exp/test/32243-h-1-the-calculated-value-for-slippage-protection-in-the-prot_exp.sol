// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./32243-h-1-the-calculated-value-for-slippage-protection-in-the-prot.sol";

contract Finding32243Test is Test {
    function test_fill_1980_is_below_the_2475_floor() public {
        Exploit e = new Exploit();
        e.run();

        console2.log("expected", e.collector().expectedExchange());
        console2.log("quoted min", e.quotedMin());
        console2.log("intended min", e.intendedMin());
        console2.log("filled", e.filled());
        console2.log("shortfall", e.shortfall());

        assertEq(e.collector().expectedExchange(), 2_000 ether, "expected");
        assertEq(e.quotedMin(), 1_980 ether, "min");
        assertEq(e.intendedMin(), 2_475 ether, "fair");
        assertEq(e.filled(), 1_980 ether, "fill");
        assertLt(e.filled(), e.intendedMin(), "worse");
        assertEq(e.shortfall(), 495 ether, "short");
        assertEq(e.token().balanceOf(address(e)), 495 ether, "attacker");
    }

    function test_control_rejects_1980_and_fills_2475() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("rejected", e.controlRejected());
        console2.log("control filled", e.controlFilled());

        assertTrue(e.controlRejected(), "1980 rejected");
        assertEq(e.controlFilled(), 2_475 ether, "fair fill");
    }
}
