// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./15977-h-04-anyone-can-prevent-themselves-from-being-liquidated-as.sol";

contract PoC_15977 is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
