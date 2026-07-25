// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./42336-h-14-anyone-can-arbitrarily-mint-fungible-tokens-in-vaderpoo.sol";

contract PoC_42336 is Test {
    function testExploit() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.proven(), "harm was not reproduced");
    }
}
