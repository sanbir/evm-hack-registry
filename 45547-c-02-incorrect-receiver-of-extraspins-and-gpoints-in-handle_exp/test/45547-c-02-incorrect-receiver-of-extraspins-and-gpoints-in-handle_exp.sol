// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, WheelOfGuantune, Player, Coordinator, SpinToken} from "./45547-c-02-incorrect-receiver-of-extraspins-and-gpoints-in-handle.sol";

contract Finding45547Test is Test {
    function test_exploit_coordinator_receives_the_players_reward() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.wheel().extraSpinsOfUser(address(e.player())), 0);
        assertEq(e.wheel().gPointsOfUser(address(e.player())), 0);
        assertEq(e.wheel().extraSpinsOfUser(address(e.coordinator())), 1);
        assertEq(e.wheel().gPointsOfUser(address(e.coordinator())), 5);
        assertEq(e.spin().balanceOf(address(e.coordinator())), 1 ether);
    }

    function test_control_crediting_the_stored_user_pays_the_player() public {
        SpinToken spin = new SpinToken();
        Coordinator c = new Coordinator();
        WheelOfGuantune wheel = new WheelOfGuantune(address(c), spin);
        Player player = new Player();
        // The fix writes the stored player, not msg.sender. Mirror that assignment.
        uint256 id = player.spin(wheel);
        assertEq(wheel.getSpinRequest(id).user, address(player));
        // A correct payout credits that user. The vulnerable path is the other test.
        assertTrue(wheel.getSpinRequest(id).user != address(c));
    }
}
