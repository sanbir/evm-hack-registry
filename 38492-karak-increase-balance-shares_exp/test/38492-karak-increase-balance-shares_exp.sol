// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38492-karak-increase-balance-shares.sol";

contract Poc38492Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.attack();
        assertTrue(e.success(), "reduced model did not reproduce 38492");
    }
}

