// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58383-lend-cross-chain-liquidation-uses-the-wrong-srctoken.sol";

contract Finding58383Test is Test {
    function testFinding58383() public {
        Exploit e = new Exploit();
        e.run();

        // Buggy pipeline forwards the DESTINATION-chain token as srcToken; the verbatim
        // findCrossChainCollateral cannot match the stored (SOURCE-chain) record, so the
        // settlement leg reverts — the cross-chain liquidation is DoS'd.
        assertTrue(e.buggyReverted(), "buggy settlement must revert");
        assertFalse(e.foundWithWrongSrcToken(), "wrong srcToken must not match");
        assertTrue(e.foundWithCorrectSrcToken(), "correct srcToken must match");

        // Debt survives the failed liquidation; the positive control with the correct
        // srcToken clears it — isolating the srcToken argument as the sole root cause.
        assertEq(e.debtAfterBuggy(), 1000e18, "debt must remain after failed liquidation");
        assertEq(e.debtAfterCorrect(), 0, "correct srcToken clears the debt");

        // Seized collateral is stuck (measurable at SINK): borrower loses collateral
        // with no debt relief.
        assertEq(e.profit(), 1000e18, "seized collateral stuck at sink");
        assertGt(e.profit(), 0);

        emit log_named_uint("stuck_collateral_wei", e.profit());
        emit log_named_uint("debt_after_buggy", e.debtAfterBuggy());
        emit log_named_uint("debt_after_correct", e.debtAfterCorrect());
    }
}
