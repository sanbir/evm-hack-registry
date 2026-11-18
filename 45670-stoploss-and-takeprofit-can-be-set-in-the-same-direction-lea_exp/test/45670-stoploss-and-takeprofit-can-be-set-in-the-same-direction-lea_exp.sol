// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./45670-stoploss-and-takeprofit-can-be-set-in-the-same-direction-lea.sol";
import {SetupGameFixed} from "./45670-stoploss-and-takeprofit-can-be-set-in-the-same-direction-lea.sol";

contract Finding45670Test is Test {

    function test_exploit_stop_takes_pot() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.slWon(), "stop");
        assertEq(e.paid(), 200 ether, "pot");
        assertEq(e.token().balanceOf(address(this)), 200 ether, "attacker");
        assertEq(e.token().balanceOf(address(e)), 0, "tp");
    }

    function test_control_and_rejects_same_direction() public {
        SetupGameFixed fixedGame = new SetupGameFixed();
        bool reverted;
        try fixedGame.createSetup(true, 20, 15) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "and rejects");
        fixedGame.createSetup(true, 20, 5);
    }

}
