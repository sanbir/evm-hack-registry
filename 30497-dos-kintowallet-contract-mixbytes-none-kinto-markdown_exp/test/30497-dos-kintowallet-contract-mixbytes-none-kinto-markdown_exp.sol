// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./30497-dos-kintowallet-contract-mixbytes-none-kinto-markdown.sol";

contract Finding30497Test is Test {
    function test_policy_stays_2_and_1000_is_stuck() public {
        Exploit e = new Exploit();
        e.run();

        console2.log("policy", e.policyAfter());
        console2.log("owners", e.ownersAfter());
        console2.log("moved", e.moved());
        console2.log("stuck", e.stuck());

        assertEq(e.policyAfter(), 2, "policy");
        assertEq(e.ownersAfter(), 1, "owners");
        assertFalse(e.moved(), "execute");
        assertEq(e.stuck(), 1_000 ether, "stuck");
    }

    function test_control_resets_policy_and_pays_1000() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("control moved", e.controlMoved());
        console2.log("control balance", e.controlBalance());

        assertTrue(e.controlMoved(), "execute");
        assertEq(e.controlBalance(), 1_000 ether, "paid");
    }
}
