// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./53318-c-07-unrestricted-omoagentonerc721received-allows-permanent.sol";

contract Finding53318Test is Test {
    function test_fake_position_id_bricks_topoff_and_locks_1000() public {
        Exploit e = new Exploit();
        e.run();
        console2.log("stuck", e.stuck());
        assertEq(e.stuck(), 1_000 ether, "stuck");
        assertEq(e.asset().balanceOf(address(e.agent())), 1_000 ether, "agent");
        assertEq(e.agent().positionCount(), 2, "ids");
    }

    function test_control_hook_does_not_track_and_pays_1000() public {
        Exploit e = new Exploit();
        e.runControl();
        console2.log("control paid", e.controlPaid());
        assertEq(e.controlPaid(), 1_000 ether, "paid");
        assertEq(e.asset().balanceOf(address(e.fixedAgent())), 0, "empty");
    }
}
