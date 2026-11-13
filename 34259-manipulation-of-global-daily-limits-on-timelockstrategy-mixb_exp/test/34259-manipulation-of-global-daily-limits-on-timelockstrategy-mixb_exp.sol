// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./34259-manipulation-of-global-daily-limits-on-timelockstrategy-mixb.sol";

contract FindingTest is Test {
    function test_attack() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.attackerDelay(), 3600);
        assertEq(e.victimDelay(), 86400);
        assertEq(e.victimLocked(), 10 ether);
        assertTrue(e.claimReverted());
        assertEq(e.token().balanceOf(address(e.market())), 1010 ether);
    }

    function test_control() public {
        Exploit e = new Exploit();
        e.runControl();
    }
}
