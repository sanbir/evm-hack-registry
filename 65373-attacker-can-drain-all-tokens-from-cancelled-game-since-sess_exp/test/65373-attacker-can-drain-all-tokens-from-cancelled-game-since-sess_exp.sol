// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65373-attacker-can-drain-all-tokens-from-cancelled-game-since-sess.sol";

contract RefundCancelledDrainTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.tok().balanceOf(address(e.attacker())), e.FEE(), "attacker drained fee");
        assertEq(e.tok().balanceOf(address(e.sm())), 0, "session manager empty");
    }

    function test_control_joinedUserCanRefund() public {
        MockToken tok = new MockToken();
        SessionManager sm = new SessionManager();
        address player = address(0xBEEF);
        tok.mint(player, 10 ether);
        sm.createGame(10 ether, address(tok));
        vm.startPrank(player);
        tok.approve(address(sm), 10 ether);
        sm.joinGame(1);
        vm.stopPrank();
        sm.cancelGame(1);
        vm.prank(player);
        sm.refundCancelledGame(1);
        assertEq(tok.balanceOf(player), 10 ether);
    }
}
