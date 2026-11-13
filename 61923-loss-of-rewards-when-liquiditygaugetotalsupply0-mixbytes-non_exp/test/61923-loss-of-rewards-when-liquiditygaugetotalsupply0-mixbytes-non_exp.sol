// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit} from "./61923-loss-of-rewards-when-liquiditygaugetotalsupply0-mixbytes-non.sol";

contract Finding61923Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.claimedAmt(), 0, "claimed");
        assertEq(e.stuck(), 1000 ether, "stuck");
        console2.log("rewards stuck", e.stuck());
    }

    function test_control() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertEq(c.claimedAmt(), 1000 ether, "claimed");
        assertEq(c.stuck(), 0, "stuck");
        console2.log("control claimed", c.claimedAmt());
    }
}
