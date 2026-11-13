// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./53523-toke-6-loss-of-reward-from-destinationvaultmainrewarder-if-t.sol";

contract Finding53523Test is Test {
    function test_empty_destination_drops_250_of_rewards() public {
        Exploit e = new Exploit();
        e.run();
        console2.log("lost", e.lost());
        assertEq(e.lost(), 250 ether, "lost");
        assertEq(e.pool().totalIdle(), 0, "idle");
        assertEq(e.pool().debtReportQueue().length(), 0, "queue");
    }

    function test_control_claims_250_into_totalIdle() public {
        Exploit e = new Exploit();
        e.runControl();
        console2.log("control idle", e.controlIdle());
        assertEq(e.controlIdle(), 250 ether, "idle");
        assertEq(e.token().balanceOf(address(e.fixedPool().rewarder())), 0, "empty");
    }
}
