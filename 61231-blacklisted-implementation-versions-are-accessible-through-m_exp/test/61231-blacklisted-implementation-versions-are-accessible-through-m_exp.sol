// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./61231-blacklisted-implementation-versions-are-accessible-through-m.sol";
contract Finding61231Test is Test {
    function test_exploit_blacklisted_impl_sweeps() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.swept(), 1_000e18, "moved 1000");
        assertTrue(e.createBlocked(), "create blocked");
        assertTrue(e.controlBlocked(), "control blocked");
        assertEq(e.controlLeft(), 1_000e18, "control kept 1000");
        assertEq(e.dai().balanceOf(address(this)), 1_000e18, "caller received 1000");
    }
}
