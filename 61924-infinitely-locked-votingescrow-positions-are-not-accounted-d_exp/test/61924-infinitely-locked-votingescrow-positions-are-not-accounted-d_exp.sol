// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit} from "./61924-infinitely-locked-votingescrow-positions-are-not-accounted-d.sol";

contract Finding61924Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.biasA(), 0, "biasA");
        assertEq(e.biasB(), 100 ether, "biasB");
        assertEq(e.alicePaid(), 0, "alice");
        assertEq(e.bobPaid(), 10_000 ether, "bob");
        console2.log("bob took", e.bobPaid());
        console2.log("alice got", e.alicePaid());
    }

    function test_control() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertEq(c.alicePaid(), 9900 ether, "alice");
        assertEq(c.bobPaid(), 100 ether, "bob");
        console2.log("control alice", c.alicePaid());
    }
}
