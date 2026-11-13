// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Cash} from "./13826-tokens-are-unlocked-only-when-delegation-ends-addressed-cons.sol";

contract Finding13826Test is Test {
    function test_half_delegated_stays_locked_until_control_unlocks() public {
        vm.warp(8_000_000);
        Exploit e = new Exploit();
        e.run();

        Cash cash = e.cash();
        assertFalse(e.buggyClaimed(), "buggy");
        assertEq(e.controlClaimed(), e.N(), "control");
        assertEq(cash.balanceOf(address(e.holder())), e.N(), "paid");

        console2.log("buggy claim");
        console2.log(e.buggyClaimed() ? 1 : 0);
        console2.log("control unlocked");
        console2.log(e.controlClaimed());
    }
}
