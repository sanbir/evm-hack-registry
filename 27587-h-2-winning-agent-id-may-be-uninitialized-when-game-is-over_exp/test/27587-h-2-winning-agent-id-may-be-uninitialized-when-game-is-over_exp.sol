// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./27587-h-2-winning-agent-id-may-be-uninitialized-when-game-is-over.sol";

contract FindingTest is Test {
    function test_prize_locked() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.parked(), e.N(), "parked");
        assertEq(e.winnerId(), 0, "id");
        assertTrue(e.claimReverted(), "claim");
        assertEq(e.stuck(), e.N(), "stuck");
        assertEq(e.winnerGot(), 0, "winner");
        assertEq(e.controlId(), 1, "control id");
        assertEq(e.controlPaid(), e.N(), "control paid");
        assertEq(e.controlLeft(), 0, "control left");
        console2.log("parked");
        console2.log(e.parked());
        console2.log("winner id");
        console2.log(e.winnerId());
        console2.log("stuck");
        console2.log(e.stuck());
        console2.log("control id");
        console2.log(e.controlId());
        console2.log("control paid");
        console2.log(e.controlPaid());
    }
}
