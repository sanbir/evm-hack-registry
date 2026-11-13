// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./55693-h-02-emissionschedulerepochemission-lacks-access-control-and.sol";

contract Finding55693Test is Test {
    function test_harm_and_control() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_uint("sneaky", e.sneaky());
        emit log_named_uint("wipedMint", e.wipedMint());
        emit log_named_uint("kept", e.kept());
        assertEq(e.sneaky(), 200 ether);
        assertEq(e.wipedMint(), 0);
        assertTrue(e.blocked());
        assertEq(e.kept(), 200 ether);
    }
}
