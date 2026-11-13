// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./53522-toke-4-incorrect-updating-of-lastupdateblock-could-result-in.sol";

contract Finding53522Test is Test {
    function test_empty_window_strands_500() public {
        Exploit e = new Exploit();
        e.run();
        console2.log("lost", e.lost());
        assertEq(e.lost(), 500 ether, "lost");
        assertEq(e.token().balanceOf(address(e.rewarder())), 500 ether, "stuck");
        assertEq(e.token().balanceOf(e.ALICE()) + e.token().balanceOf(e.BOB()), 1_000 ether, "paid");
    }

    function test_control_queues_and_pays_the_500() public {
        Exploit e = new Exploit();
        e.runControl();
        console2.log("queued paid", e.queuedPaid());
        assertEq(e.queuedPaid(), 500 ether, "queued");
        assertEq(e.token().balanceOf(address(e.fixedRewarder())), 0, "empty");
    }
}
