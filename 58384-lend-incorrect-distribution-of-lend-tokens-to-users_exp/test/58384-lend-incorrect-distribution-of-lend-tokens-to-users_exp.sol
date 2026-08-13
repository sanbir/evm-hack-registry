// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, MiniToken, LendStorage, CrossChainRouter} from "./58384-lend-incorrect-distribution-of-lend-tokens-to-users.sol";

// LEND (Sherlock 2025-05) H-15 (finding 58384): _handleBorrowCrossChainRequest
// updates the crossChainCollaterals mapping BEFORE calling distributeBorrowerLend,
// so the verbatim reward accounting reads the inflated balance and over-credits
// LEND. Same verbatim distributeBorrowerLend run in the correct order accrues less.
contract Finding58384Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_incorrectLendDistribution_overCredits() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("attacker LEND accrued (buggy order)", e.attackerAccrued());
        emit log_named_uint("reference LEND accrued (correct order)", e.referenceAccrued());
        emit log_named_uint("over-credited LEND", e.overCredit());

        // buggy update-then-distribute over-credits relative to the correct order
        assertGt(e.attackerAccrued(), e.referenceAccrued(), "no over-distribution");
        // excess equals the reward on the freshly-borrowed 1000e18 over one index period
        assertEq(e.overCredit(), 1000e18, "unexpected over-credit magnitude");
        assertEq(e.attackerAccrued(), 2000e18, "attacker accrual not doubled");
        assertEq(e.referenceAccrued(), 1000e18, "reference accrual wrong");

        // surplus materialized as a measurable LEND balance at the sink
        assertEq(e.lend().balanceOf(SINK), 1000e18, "surplus not materialized");
    }
}
