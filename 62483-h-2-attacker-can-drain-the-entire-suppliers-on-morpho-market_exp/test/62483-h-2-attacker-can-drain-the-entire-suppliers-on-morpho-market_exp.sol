// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62483-h-2-attacker-can-drain-the-entire-suppliers-on-morpho-market.sol";

contract MorphoDrainTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
