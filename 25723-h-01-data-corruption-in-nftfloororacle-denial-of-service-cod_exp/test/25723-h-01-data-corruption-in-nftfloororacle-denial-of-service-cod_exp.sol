// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./25723-h-01-data-corruption-in-nftfloororacle-denial-of-service-cod.sol";

contract PoC_25723 is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
