// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit} from "./61822-h-01-lack-of-access-control-in-agentnftv2addvalidator-enable.sol";

contract Finding61822Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.listLength(), 2, "duplicate");
        assertEq(e.poolAccounted(), 1000 ether, "pool");
        assertEq(e.treasuryGot(), 1000 ether, "treasury");
        assertTrue(e.claimFailed(), "claim failed");
        assertEq(e.founderGot(), 0, "founder");
        assertEq(e.shortfall(), 500 ether, "shortfall");
        console2.log("founder shortfall", e.shortfall());
        console2.log("treasury got", e.treasuryGot());
    }

    function test_control() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertEq(c.listLength(), 1, "one");
        assertEq(c.poolAccounted(), 500 ether, "pool");
        assertEq(c.treasuryGot(), 500 ether, "treasury");
        assertEq(c.founderGot(), 500 ether, "founder");
        console2.log("control founder", c.founderGot());
    }
}
