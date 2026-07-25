// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./18534-h-2-earlier-users-in-rollover-queue-can-grief-later-users-sh.sol";

contract PoC_18534 is Test {
    function testExploit() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.proven(), "harm was not reproduced");
    }
}
