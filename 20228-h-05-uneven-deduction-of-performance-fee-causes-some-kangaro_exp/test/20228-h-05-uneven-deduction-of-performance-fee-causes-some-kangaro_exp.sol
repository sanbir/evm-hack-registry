// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20228-h-05-uneven-deduction-of-performance-fee-causes-some-kangaro.sol";

/// @dev forge-std driver for the reduced Polynomial H-05 PoC.
contract UnevenPerformanceFeeTest is Test {
    Exploit exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_unevenPerformanceFee() public {
        exploit.run();

        uint256 payout2 = exploit.payout2();
        uint256 payout3 = exploit.payout3();
        MockERC20 susd = exploit.susd();

        // Equal deposits, unequal payouts.
        assertEq(payout2, 15e18, "frontrunner payout");
        assertEq(payout3, 13e18, "victim payout");
        assertGt(payout2, payout3, "distribution should be uneven");

        // The whole 2e18 performance fee fell on the late holder.
        assertEq(payout2 - payout3, 2e18, "gap should equal the fee");
        assertLt(payout3, 14e18, "victim should be below fair (14e18)");
        assertGt(payout2, 14e18, "frontrunner should be above fair (14e18)");

        // Fee sink received the fee; vault drained.
        assertEq(susd.balanceOf(exploit.FEE_SINK()), 2e18, "fee sink balance");
        assertEq(susd.balanceOf(address(exploit.vault())), 0, "vault should be empty");
    }
}
