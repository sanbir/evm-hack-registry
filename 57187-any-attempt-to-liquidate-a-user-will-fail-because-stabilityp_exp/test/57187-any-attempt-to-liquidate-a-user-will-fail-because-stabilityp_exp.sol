// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./57187-any-attempt-to-liquidate-a-user-will-fail-because-stabilityp.sol";

contract LiquidationFailsTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.liquidationReverted(), "liquidation must fail");
        assertEq(e.spCrvBalance(), 0, "SP holds no crvUSD");
        assertTrue(e.borrowerStillInDebt(), "borrower unliquidatable");
    }
}
