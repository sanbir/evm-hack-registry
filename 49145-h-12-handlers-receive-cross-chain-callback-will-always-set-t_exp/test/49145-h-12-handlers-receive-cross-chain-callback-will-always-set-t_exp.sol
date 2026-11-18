// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit} from "./49145-h-12-handlers-receive-cross-chain-callback-will-always-set-t.sol";
contract Finding49145Test is Test {
    function test_exploit_failed_message_still_burns() public {
        Exploit e = new Exploit();
        e.run();
        (, uint8 status) = e.handler().created(1);
        assertEq(status, 2);
        assertEq(e.token().balanceOf(address(e.sink())), 1000 ether);
        assertEq(e.token().balanceOf(address(e.handler())), 0);
    }
}
