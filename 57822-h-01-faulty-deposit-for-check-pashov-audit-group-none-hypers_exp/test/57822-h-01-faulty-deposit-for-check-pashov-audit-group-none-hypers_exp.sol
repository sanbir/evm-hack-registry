// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Distributor,
    Exploit,
    Reward,
    VePeg
} from "./57822-h-01-faulty-deposit-for-check-pashov-audit-group-none-hypers.sol";

contract Finding57822Test is Test {
    function test_perpetual_lock_is_credited_zero() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.claimReverted(), "claim reverts");
        assertEq(e.credited(), 0, "credited 0");
        assertEq(e.stillPending(), 100 ether, "100 still pending");
        assertEq(e.stuck(), 100 ether, "100 stuck in the distributor");
        (uint256 amount,,) = e.ve().locked(1);
        assertEq(amount, 10 ether, "lock amount unchanged");
    }

    function test_control_credits_the_perpetual_lock() public {
        Reward token = new Reward();
        VePeg ve = new VePeg(token, true);
        Distributor dist = new Distributor(token, ve);
        ve.createPerpetual(1, address(this), 10 ether);
        token.mint(address(this), 100 ether);
        token.approve(address(dist), 100 ether);
        dist.fund(1, 100 ether);
        uint256 paid = dist.claim(1);

        assertEq(paid, 100 ether, "claim returns 100");
        (uint256 amount,,) = ve.locked(1);
        assertEq(amount, 110 ether, "the lock is credited 100");
        assertEq(ve.perpetuallyLockedBalance(), 100 ether, "perpetual balance increased by 100");
        assertEq(token.balanceOf(address(ve)), 100 ether, "ve holds the 100");
        assertEq(dist.pending(1), 0, "pending cleared");
    }
}
