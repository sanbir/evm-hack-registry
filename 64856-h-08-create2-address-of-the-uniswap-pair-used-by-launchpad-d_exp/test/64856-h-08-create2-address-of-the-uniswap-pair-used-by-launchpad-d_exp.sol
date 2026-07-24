// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64856-h-08-create2-address-of-the-uniswap-pair-used-by-launchpad-d.sol";

contract PairForMismatchTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.stuck(), "graduation stuck");
        assertTrue(e.wrongPredicted() != e.realPair(), "pair addresses differ");
    }
}
