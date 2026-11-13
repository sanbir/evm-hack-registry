// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit} from "./61789-flashloan-functionality-is-blocked-openzeppelin-none-fx-v2-a.sol";

contract Finding61789Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.loanReverted(), "reverted");
        assertEq(e.borrowerEnd(), 100 ether, "prefund stuck");
        assertEq(e.deskEnd(), 1000 ether, "arb unpaid");
        assertEq(e.treasuryEnd(), 0, "no fee");
        assertEq(e.missedNet(), 900 ether, "missed 900");
        console2.log("missed net", e.missedNet());
    }

    function test_control() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertEq(c.borrowerEnd(), 1000 ether, "arb kept");
        assertEq(c.deskEnd(), 0, "desk");
        assertEq(c.treasuryEnd(), 100 ether, "fee");
        assertEq(c.net(), 900 ether, "net");
        console2.log("control net", c.net());
    }
}
