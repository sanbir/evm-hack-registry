// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./51369-withdrawals-are-blocked-due-to-wrong-function-name-on-the-cu.sol";
contract CurveConvexTypoTest is Test {
    function test_exploit_blocks_withdrawal_and_locks_lp() public {
        Exploit e = new Exploit(); e.run();
        assertTrue(e.withdrawalBlocked());
        assertEq(e.lp().balanceOf(address(e.chef())), 100);
        assertEq(e.lp().balanceOf(address(e)), 0);
    }
}