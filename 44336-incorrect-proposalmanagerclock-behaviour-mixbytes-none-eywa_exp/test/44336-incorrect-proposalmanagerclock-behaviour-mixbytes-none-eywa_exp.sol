// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./44336-incorrect-proposalmanagerclock-behaviour-mixbytes-none-eywa.sol";

contract Finding44336Test is Test {
    function test_clock_uses_block_number() public {
        vm.roll(100);
        vm.warp(1_700_000_000);
        Exploit e = new Exploit();
        e.run();
        assertEq(e.mgr().proposalSnapshot(), 172900, "buggy snapshot");
        assertEq(e.mgr().proposalDeadline(), 777700, "buggy deadline");
        assertEq(e.mgr().fairSnapshot(), 1_700_172_800, "fair snapshot");
        assertEq(e.mgr().state(), 2, "Defeated");
        assertEq(e.mgr().fairState(), 0, "Pending");
        console2.log("snapshot", e.mgr().proposalSnapshot());
        console2.log("fair snapshot", e.mgr().fairSnapshot());
        console2.log("state", e.mgr().state());
        console2.log("fair state", e.mgr().fairState());
    }
}
