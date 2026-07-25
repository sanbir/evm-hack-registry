// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./31275-failure-to-add-modified-facets-and-facets-with-modified-depe.sol";

contract PoC_31275 is Test {
    function testExploit() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.proven(), "harm was not reproduced");
    }
}
