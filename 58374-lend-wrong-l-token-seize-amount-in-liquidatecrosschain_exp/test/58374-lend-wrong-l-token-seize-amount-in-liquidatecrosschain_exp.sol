// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, CrossChainRouter, Lendtroller, MiniLToken} from "./58374-lend-wrong-l-token-seize-amount-in-liquidatecrosschain.sol";

// LEND H-5 (finding 58374): liquidateCrossChain computes seizeTokens on Chain B
// with the Chain B collateral lToken's exchange rate (0.2), but the seize is
// applied to the Chain A collateral lToken (rate 0.4). The protocol seizes
// 550e18 lTokens from the borrower when the correct amount is 275e18 — an extra
// 275e18 collateral lTokens robbed from the borrower and handed to the liquidator.
contract Finding58374Test is Test {
    function test_exploit_wrongCrossChainSeizeAmount_overSeizesBorrower() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("wrong seize (Chain B rate)", e.wrongSeize());
        emit log_named_uint("correct seize (Chain A rate)", e.correctSeizeTokens());
        emit log_named_uint("borrower loss", e.borrowerLoss());
        emit log_named_uint("liquidator gain", e.liquidatorGain());
        emit log_named_uint("over-seized (theft)", e.overSeized());

        assertEq(e.wrongSeize(), 550 ether, "seize used Chain B exchange rate");
        assertEq(e.correctSeizeTokens(), 275 ether, "correct Chain A seize");
        assertEq(e.borrowerLoss(), 550 ether, "borrower over-seized");
        assertEq(e.liquidatorGain(), 550 ether, "liquidator received wrong seize");
        assertGt(e.borrowerLoss(), e.correctSeizeTokens(), "over-seizure occurred");
        assertEq(e.overSeized(), 275 ether, "excess robbed from borrower");
        assertEq(e.profit(), 275 ether, "bug-attributable theft magnitude");
    }
}
