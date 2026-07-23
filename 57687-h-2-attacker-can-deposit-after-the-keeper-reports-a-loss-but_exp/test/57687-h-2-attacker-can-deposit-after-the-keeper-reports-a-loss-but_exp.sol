// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./57687-h-2-attacker-can-deposit-after-the-keeper-reports-a-loss-but.sol";

/* Yearn yBOLD — H-2 free-ride deposit after loss report (Sherlock 2025-05) */
contract PoC_57687 is Test {
    function test_depositAfterLossFreeRide() public {
        Exploit e = new Exploit();
        e.run();

        // Attacker steals >30% of victim deposit (finding shows ~32.5e18 on 100e18)
        assertGt(e.attackerProfit(), 30e18);
        assertGt(e.userLoss(), 30e18);
        assertApproxEqAbs(e.attackerProfit(), e.userLoss(), 1e18);
    }
}
