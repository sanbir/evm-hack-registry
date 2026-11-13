// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./35996-fraudulent-messages-may-be-sent-through-the-bridge-sigmaprim.sol";

contract Finding35996Test is Test {
    function test_any_caller_credits_100() public {
        Exploit e = new Exploit();
        e.run();

        console2.log("got", e.got());
        console2.log("released", e.bridge().released());

        assertEq(e.got(), 100 ether, "credited");
        assertEq(e.bridge().released(), 100 ether, "released");
        assertEq(e.token().balanceOf(address(e.bridge())), 0, "bridge empty");
    }

    function test_control_rejects_signal_service_as_target() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("blocked", e.controlBlocked());
        assertTrue(e.controlBlocked(), "reverted");
        assertEq(e.token().balanceOf(address(e)), 0, "no credit");
    }
}
