// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62973-accountableopenterm-loan-interest-cannot-be-repaid-once-prin.sol";

contract AccountableInterestUnpayableTest is Test {
    function test_exploit_principalOnlyRepayForgivesInterest() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.supplyBlocked(), "supply blocked after Repaid");
        assertEq(e.sharePriceAfter(), 1e36, "share price fell back to 1:1");
        assertGt(e.interestForgiven(), 0, "interest was accrued then forgiven");
        assertEq(uint8(e.loan().loanState()), uint8(LoanState.Repaid), "loan Repaid");
    }
}
