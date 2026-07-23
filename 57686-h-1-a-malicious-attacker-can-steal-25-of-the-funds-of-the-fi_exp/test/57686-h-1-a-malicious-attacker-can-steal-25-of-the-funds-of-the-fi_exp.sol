// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./57686-h-1-a-malicious-attacker-can-steal-25-of-the-funds-of-the-fi.sol";

/* Yearn yBOLD — H-1 first depositor inflation steals 25% (Sherlock 2025-05) */
contract PoC_57686 is Test {
    function test_steal25pctFirstDepositor() public {
        Exploit e = new Exploit();
        e.run();

        // Attacker profits ~25% of the 1e23 deposit
        assertGt(e.attackerProfit(), 2e22);
        assertGt(e.userLoss(), 2e22);
        // Roughly equal transfer of value
        assertApproxEqAbs(e.attackerProfit(), e.userLoss(), 1e18);
    }
}
