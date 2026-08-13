// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, LendStorage, CoreRouter, MockLToken, MarkerToken} from "./58392-lend-cross-chain-collateral-is-miscalculated-in-borrowwithinterest.sol";

// Lend V2 H-23 (finding 58392): borrowWithInterest only counts a cross-chain
// collateral when destEid == currentEid && srcEid == currentEid, which is never
// true (srcEid != destEid), so a live 100e18 cross-chain debt is reported as 0
// and the borrower's repayment reverts on "Borrowed amount is 0". The 100e18
// uncloseable-debt magnitude is booked to the SINK for a measurable harm.
contract Finding58392Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_crossChainDebtMiscountedAsZero() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("true cross-chain debt", e.trueDebt());
        emit log_named_uint("reported by borrowWithInterest", e.reportedDebt());

        assertEq(e.trueDebt(), 100e18, "borrower genuinely owes 100e18 cross-chain");
        assertEq(e.reportedDebt(), 0, "vulnerable borrowWithInterest miscounts the debt as 0");
        assertTrue(e.repayReverted(), "repayment reverts on the zeroed debt guard");

        // The transfer-less DoS/accounting harm is measurable at the SINK.
        MarkerToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), 100e18, "harm magnitude (uncloseable debt) booked to SINK");
    }
}
