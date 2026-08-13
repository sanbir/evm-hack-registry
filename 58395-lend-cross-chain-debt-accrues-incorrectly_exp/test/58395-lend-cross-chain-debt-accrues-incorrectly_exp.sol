// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, LendStorage, LToken, MiniToken} from "./58395-lend-cross-chain-debt-accrues-incorrectly.sol";

// Lend-V2 H-26 (finding 58395): borrowWithInterest scales a cross-chain (destination)
// debt by the SAME-CHAIN _lToken.borrowIndex() instead of the destination chain's
// index, so the accrued debt is mis-counted. Local index 1.0e18 vs true dest index
// 1.5e18 -> protocol reports 1000e18 debt when the borrower actually owes 1500e18.
contract Finding58395Test is Test {
    function test_exploit_crossChainDebtUsesWrongIndex() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("reported debt (buggy)", e.reportedDebt());
        emit log_named_uint("true debt (dest index)", e.trueDebt());
        emit log_named_uint("under-counted bad debt", e.underCounted());

        assertEq(e.reportedDebt(), 1000 ether, "buggy same-chain-index debt");
        assertEq(e.trueDebt(), 1500 ether, "correct destination-index debt");
        assertLt(e.reportedDebt(), e.trueDebt(), "debt is mis-accrued (under-counted)");
        assertEq(e.underCounted(), 500 ether, "500e18 of debt silently uncounted");
    }
}
