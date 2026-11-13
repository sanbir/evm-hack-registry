// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./26293-cancelling-an-auction-refunds-the-wrong-amount-for-unreveale.sol";

contract FindingTest is Test {
    function test_wrong_refund() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.parked(), e.LOCKED(), "parked");
        assertEq(e.refunded(), e.REVEALED(), "refunded");
        assertEq(e.stuck(), e.LOCKED() - e.REVEALED(), "stuck");
        assertEq(e.offerorGot(), e.REVEALED(), "offeror");
        assertEq(e.controlRefunded(), e.LOCKED(), "control refund");
        assertEq(e.controlLeft(), 0, "control left");
        assertEq(e.controlGot(), e.LOCKED(), "control got");
        console2.log("parked");
        console2.log(e.parked());
        console2.log("refunded");
        console2.log(e.refunded());
        console2.log("stuck");
        console2.log(e.stuck());
        console2.log("control refunded");
        console2.log(e.controlRefunded());
        console2.log("control left");
        console2.log(e.controlLeft());
    }
}
