// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./15983-h-10-attacker-can-drain-pool-using-executebuywithcredit-with.sol";

contract PoC_15983 is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
