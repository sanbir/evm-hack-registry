// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./50695-user-funds-may-get-locked-in-join-contracts-halborn-damfinan.sol";

contract Finding50695Test is Test {
    function test_cage_locks_joined_tokens_and_control_exits() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.exitReverted(), "exit");
        assertEq(e.stillInJoin(), e.N(), "locked");
        assertEq(e.controlPaid(), e.N(), "control");
        assertEq(e.locked(), e.N(), "harm");

        console2.log("exit reverted");
        console2.log(e.exitReverted() ? 1 : 0);
        console2.log("tokens still in join");
        console2.log(e.stillInJoin());
        console2.log("control paid back");
        console2.log(e.controlPaid());
    }
}
