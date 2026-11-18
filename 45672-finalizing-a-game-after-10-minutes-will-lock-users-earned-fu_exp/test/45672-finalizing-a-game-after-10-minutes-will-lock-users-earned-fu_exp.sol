// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./45672-finalizing-a-game-after-10-minutes-will-lock-users-earned-fu.sol";

contract FindingTest is Test {
    function test_exploit() public {
        vm.warp(1_700_000_000);
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.reverted());
        assertEq(e.downRefunded(), 100 ether);
        assertEq(e.controlUpPaid(), 200 ether);
    }
}
