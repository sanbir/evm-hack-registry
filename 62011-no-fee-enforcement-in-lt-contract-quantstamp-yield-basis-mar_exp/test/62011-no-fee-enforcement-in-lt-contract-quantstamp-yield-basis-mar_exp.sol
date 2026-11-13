// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit} from "./62011-no-fee-enforcement-in-lt-contract-quantstamp-yield-basis-mar.sol";

contract Finding62011Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.feePaid(), 0, "fee");
        assertEq(e.lpGot(), 1000 ether, "lp");
        console2.log("fee paid", e.feePaid());
        console2.log("lp kept", e.lpGot());
    }

    function test_control() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertEq(c.feePaid(), 100 ether, "fee");
        assertEq(c.lpGot(), 900 ether, "lp");
        console2.log("control fee", c.feePaid());
    }
}
