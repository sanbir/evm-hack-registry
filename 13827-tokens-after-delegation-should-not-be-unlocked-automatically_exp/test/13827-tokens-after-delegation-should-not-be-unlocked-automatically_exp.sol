// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Cash} from "./13827-tokens-after-delegation-should-not-be-unlocked-automatically.sol";

contract Finding13827Test is Test {
    function test_delegation_end_unlocks_early_and_control_keeps_lock() public {
        Exploit e = new Exploit();
        e.run();

        Cash cash = e.cash();
        assertEq(e.withdrawn(), e.N(), "withdrawn");
        assertEq(cash.balanceOf(address(e.holder())), e.N(), "paid");
        assertFalse(e.controlClaimed(), "control");
        assertEq(e.stillLocked(), e.PURCHASED() + e.N(), "purchased");

        console2.log("withdrawn before lock ended");
        console2.log(e.withdrawn());
        console2.log("control claim");
        console2.log(e.controlClaimed() ? 1 : 0);
        console2.log("still purchased");
        console2.log(e.stillLocked());
    }
}
