// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit} from "./62026-lockup-period-for-unstaking-can-be-decreased-by-staking-agai.sol";

contract Finding62026Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.earlyBy(), 26_312_728, "early");
        assertEq(e.locked(), 11_000 ether, "locked");
        assertLt(e.unlockAfter(), e.unlockBefore(), "order");
        console2.log("seconds early", e.earlyBy());
        console2.log("tokens pulled forward", e.locked());
    }

    function test_control() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertTrue(c.shorterReverted(), "reverted");
        assertEq(c.unlockAfter(), c.unlockBefore(), "unlock");
        assertEq(c.locked(), 1000 ether, "locked");
        console2.log("control unlock kept", c.unlockAfter());
    }
}
