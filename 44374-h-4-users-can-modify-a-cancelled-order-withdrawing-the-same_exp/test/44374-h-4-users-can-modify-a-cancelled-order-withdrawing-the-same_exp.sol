// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./44374-h-4-users-can-modify-a-cancelled-order-withdrawing-the-same.sol";

contract PoC_44374 is Test {
    function testExploit() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.proven(), "harm was not reproduced");
    }
}
