// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./26292-unlocking-offers-does-not-return-any-funds-sigmaprime-none-t.sol";

contract FindingTest is Test {
    function test_unlock_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.deposited(), e.N(), "deposited");
        assertEq(e.paid(), 0, "paid");
        assertEq(e.stuck(), e.N(), "stuck");
        assertEq(e.got(), 0, "got");
        assertEq(e.controlPaid(), e.N(), "control paid");
        assertEq(e.controlLeft(), 0, "control left");
        assertEq(e.controlGot(), e.N(), "control got");
        console2.log("deposited");
        console2.log(e.deposited());
        console2.log("paid");
        console2.log(e.paid());
        console2.log("stuck");
        console2.log(e.stuck());
        console2.log("control paid");
        console2.log(e.controlPaid());
        console2.log("control left");
        console2.log(e.controlLeft());
    }
}
