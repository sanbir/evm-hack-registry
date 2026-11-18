// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./43810-enable-mode-signature-can-be-replayed-spearbit-none-biconomy.sol";

contract Finding43810Test is Test {
    function test_exploit_replays_enable_mode_signature() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 1000 ether, "stolen");
        assertTrue(e.reinstalled(), "reinstalled");
        assertEq(e.token().balanceOf(address(e.account())), 0, "account empty");
    }

    function test_control_user_op_hash_stops_replay() public {
        Exploit e = new Exploit();
        e.runFixed();
        assertEq(e.token().balanceOf(address(e)), 0, "attacker");
    }
}
