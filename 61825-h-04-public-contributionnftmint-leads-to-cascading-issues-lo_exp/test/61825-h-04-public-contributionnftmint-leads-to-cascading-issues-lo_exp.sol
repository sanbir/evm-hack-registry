// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit} from "./61825-h-04-public-contributionnftmint-leads-to-cascading-issues-lo.sol";

contract Finding61825Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 10_000 ether, "paid");
        assertEq(e.excess(), 9900 ether, "excess");
        assertEq(e.reserveLeft(), 10_000 ether, "reserve");
        console2.log("excess paid", e.excess());
        console2.log("proposer received", e.paid());
    }

    function test_control() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertTrue(c.attackerMintReverted(), "reverted");
        assertEq(c.paid(), 100 ether, "honest");
        console2.log("control paid", c.paid());
    }
}
