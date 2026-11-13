// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./31932-h-04-taiko-l1-proposer-can-maliciously-cause-loss-of-funds-b.sol";

contract FindingTest is Test {
    function test_attack() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.victimLost(), 40 ether);
        assertEq(e.proverGained(), 40 ether);
        assertEq(e.token().balanceOf(address(e.victim())), 60 ether);
    }

    function test_control() public {
        Exploit e = new Exploit();
        e.runControl();
    }
}
