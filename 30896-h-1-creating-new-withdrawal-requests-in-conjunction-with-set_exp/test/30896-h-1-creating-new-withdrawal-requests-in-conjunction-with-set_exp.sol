// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exploit} from "./30896-h-1-creating-new-withdrawal-requests-in-conjunction-with-set.sol";

contract Finding30896Test is Test {
    function test_exploit_lateWithdrawRevertsAndLeavesTen() public {
        Exploit e = new Exploit();
        e.run();

        console.log("epoch after settle", e.epochAfterSettle());
        console.log("late reverted", e.lateWithdrawReverted());
        console.log("stuck", e.stuck());
        console.log("bob", e.token().balanceOf(address(e.bob())));
        console.log("alice", e.token().balanceOf(address(e.alice())));

        assertEq(e.epochAfterSettle(), 0, "epoch");
        assertTrue(e.lateWithdrawReverted(), "revert");
        assertEq(e.stuck(), 10 ether, "stuck");
        assertEq(e.token().balanceOf(address(e.bob())), 0, "bob");
        assertEq(e.token().balanceOf(address(e.alice())), 10 ether, "alice");
        assertEq(e.token().balanceOf(address(e.queue())), 10 ether, "queue");
    }

    function test_control_incrementedEpochPaysBobTen() public {
        Exploit e = new Exploit();
        e.control();

        assertEq(e.token().balanceOf(address(e.bob())), 10 ether, "bob paid");
        assertEq(e.token().balanceOf(address(e.alice())), 10 ether, "alice paid");
        assertEq(e.token().balanceOf(address(e.fixedQueue())), 0, "nothing stuck");
    }
}
