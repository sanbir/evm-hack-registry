// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./58388-lend-cross-chain-liquidation-reduces-debt-by-collateral-seized.sol";

// Lend (2025-05 Sherlock) H-19 finding 58388: cross-chain liquidation reuses one
// generic Payload.amount field, so `seizeTokens` (collateral to seize) is fed to
// repayCrossChainBorrowInternal as the repay amount. The borrower's debt is
// reduced by seizeTokens (540e18) instead of repayAmount (500e18).
contract Finding58388Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_debtReducedBySeizeNotRepay() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("repayAmount (intended)", e.REPAY_AMOUNT());
        emit log_named_uint("seizeTokens", e.seizeTokens());
        emit log_named_uint("debt reduced by", e.debtReducedBy());
        emit log_named_uint("mis-accounting (sink)", e.errorMagnitude());

        // seize amount and repay amount genuinely differ (the semantic confusion)
        assertEq(e.seizeTokens(), 540 ether, "seizeTokens = repay * 1.08 incentive");
        assertEq(e.REPAY_AMOUNT(), 500 ether, "intended repay amount");

        // the bug: debt is reduced by the seize amount, not the repay amount
        assertEq(e.debtReducedBy(), e.seizeTokens(), "debt cleared by seize amount");
        assertTrue(e.debtReducedBy() != e.REPAY_AMOUNT(), "debt not cleared by repay amount");

        // measurable harm magnitude minted to SINK
        assertEq(e.errorMagnitude(), 40 ether, "40e18 debt mis-accounted");
        assertEq(e.sink().balanceOf(SINK), 40 ether, "harm magnitude at sink");
    }
}
