// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./55050-double-claiming-of-accrued-rewards-via-unwinding-after-accru.sol";

contract Finding55050Test is Test {
    function test_arrival_epoch_takes_50_from_bob() public {
        Exploit e = new Exploit();
        e.run();
        console2.log("extra", e.extra());
        console2.log("bob", e.bobGot());
        assertEq(e.extra(), 50 ether, "extra");
        assertEq(e.bobGot(), 50 ether, "bob");
        assertEq(e.lockingPaid(), 100 ether, "locking");
    }

    function test_control_bob_receives_the_full_100() public {
        Exploit e = new Exploit();
        e.runControl();
        console2.log("control bob", e.controlBob());
        assertEq(e.controlBob(), 100 ether, "bob");
        assertEq(e.token().balanceOf(address(e)), 0, "carol");
    }
}
