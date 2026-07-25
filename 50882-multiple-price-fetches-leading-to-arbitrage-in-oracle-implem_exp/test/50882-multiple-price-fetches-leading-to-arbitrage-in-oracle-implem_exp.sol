// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./50882-multiple-price-fetches-leading-to-arbitrage-in-oracle-implem.sol";

contract PoC_50882 is Test {
    function testExploit() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.proven(), "harm was not reproduced");
    }
}
