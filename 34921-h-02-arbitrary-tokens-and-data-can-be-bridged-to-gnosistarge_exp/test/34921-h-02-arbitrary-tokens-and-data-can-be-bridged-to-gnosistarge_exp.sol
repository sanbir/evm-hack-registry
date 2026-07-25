// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./34921-h-02-arbitrary-tokens-and-data-can-be-bridged-to-gnosistarge.sol";

contract PoC_34921 is Test {
    function testExploit() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.proven(), "harm was not reproduced");
    }
}
