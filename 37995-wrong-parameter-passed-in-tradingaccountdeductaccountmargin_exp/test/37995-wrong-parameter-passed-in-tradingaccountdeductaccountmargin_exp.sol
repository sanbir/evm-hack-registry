// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {MockToken, TradingAccount, LiquidationBranch, Exploit} from
    "./37995-wrong-parameter-passed-in-tradingaccountdeductaccountmargin.sol";

contract WrongDeductAccountMarginParamTest is Test {
    /// @notice CONTROL — calling deductAccountMargin with the CORRECT
    ///         pnl-deduction value (as if the bug were fixed) deducts the
    ///         full real loss + fee, leaving the trader with exactly the
    ///         intended remainder.
    function test_correctPnlValue_deductsFullLoss() public {
        MockToken token = new MockToken();
        TradingAccount ta = new TradingAccount(token);
        token.mint(address(ta), 100_000e18);
        ta.credit(1, 100_000e18);

        address feeRecipient = address(0xFEE);
        uint256 liquidated = ta.deductAccountMargin(1, 60_000e18, 1_000e18, feeRecipient);

        assertEq(liquidated, 61_000e18);
        assertEq(ta.marginCollateralBalance(1), 39_000e18);
        assertEq(token.balanceOf(feeRecipient), 61_000e18);
    }

    /// @notice HARM — LiquidationBranch passes the WRONG value
    ///         (requiredMaintenanceMarginUsdX18 instead of the account's
    ///         real unrealized loss), so 30,000 less is deducted than it
    ///         should be: the fee recipient is shorted 30,000, and the
    ///         trader withdraws that exact 30,000 excess after liquidation.
    function test_wrongParameterPassed_traderKeepsExcessMargin() public {
        Exploit exploit = new Exploit();
        exploit.run();

        // Re-assert from the test's own vantage point too.
        assertEq(exploit.token().balanceOf(exploit.feeRecipient()), 31_000e18);
        assertEq(exploit.token().balanceOf(address(exploit)), 69_000e18);
    }
}
