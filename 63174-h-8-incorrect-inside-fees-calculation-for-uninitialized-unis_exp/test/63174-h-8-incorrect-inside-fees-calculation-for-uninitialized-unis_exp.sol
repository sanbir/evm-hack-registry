// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63174-h-8-incorrect-inside-fees-calculation-for-uninitialized-unis.sol";

contract AmmplifyInsideFeesTest is Test {
    function test_exploit_inflatedInsideFeesStucksPosition() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.positionStuck(), "stuck");
        assertEq(e.inflatedSnapshot(), 1e30);
    }
}
