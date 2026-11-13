// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, RaacToken, VeTokenFixed} from
    "./57208-attackers-can-double-voting-power-and-vetoken-amount-by-lock.sol";

contract Finding57208Test is Test {
    function test_exploit_dust_lock_then_increase_mints_double_ve() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.power(), 200 ether - 1, "voting power");
        assertEq(e.minted(), 200 ether - 1, "ve balance");
        assertEq(e.ve().balanceOf(address(e)), 200 ether - 1, "held by exploit");
        assertGt(e.power(), 100 ether, "more than a fair lock");
    }

    function test_control_increase_uses_the_lock_once() public {
        RaacToken raac = new RaacToken();
        VeTokenFixed ve = new VeTokenFixed(raac);
        raac.mint(address(this), 100 ether);
        raac.approve(address(ve), type(uint256).max);
        ve.lock(1, ve.MAX_LOCK_DURATION());
        ve.increase(100 ether - 1);

        assertEq(ve.balanceOf(address(this)), 100 ether, "one ve per raac");
    }
}
