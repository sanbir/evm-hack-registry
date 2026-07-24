// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./61091-folks-liquidation-mixing.sol";

contract Poc61091Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.attack();
        assertTrue(e.success(), "reduced model did not reproduce 61091");
    }
}

