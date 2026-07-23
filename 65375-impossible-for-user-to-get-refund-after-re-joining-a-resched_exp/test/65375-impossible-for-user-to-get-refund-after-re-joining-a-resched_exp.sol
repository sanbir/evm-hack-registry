// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65375-impossible-for-user-to-get-refund-after-re-joining-a-resched.sol";

contract RejoinRefundLockTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.tok().balanceOf(address(e.sm())), e.FEE(), "second fee locked");
        assertTrue(e.sm().hasRefunded(e.GAME_ID(), address(e.player())), "hasRefunded stuck true");
    }
}
