// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exploit, LenderFixed, MockToken} from "./53324-h-06-omooracle-incorrect-token-decimals-handling-in-getusdva.sol";

contract OmoOracleDecimalsTest is Test {
    function test_exploit_wrongDecimalsLetsOneDaiBorrowOneMillionUsdc() public {
        Exploit e = new Exploit();
        e.run();

        console.log("buggy debt usd", e.buggyDebtUsd());
        console.log("fair debt usd", e.fairDebtUsd());
        console.log("buggy collateral usd", e.buggyColUsd());
        console.log("fair collateral usd", e.fairColUsd());
        console.log("usdc borrowed", e.usdcOut());

        assertEq(e.buggyDebtUsd(), 1e12, "buggy USDC value");
        assertEq(e.fairDebtUsd(), 1e24, "fair USDC value");
        assertEq(e.buggyColUsd(), 1e18, "buggy DAI value");
        assertEq(e.fairColUsd(), 1e18, "fair DAI value");
        assertGe(e.buggyColUsd(), e.buggyDebtUsd(), "buggy check");
        assertLt(e.fairColUsd(), e.fairDebtUsd(), "fair check");
        assertEq(e.usdcOut(), 1_000_000e6, "borrow");
        assertEq(e.usdc().balanceOf(address(e)), 1_000_000e6, "attacker usdc");
        assertEq(e.dai().balanceOf(address(e.lender())), 1e18, "lender kept the 1 DAI");
        assertEq(e.usdc().balanceOf(address(e.lender())), 0, "lender USDC left");
    }

    function test_control_fairOracleRejectsMillionAndAllowsOneUsdc() public {
        Exploit e = new Exploit();
        MockToken dai = e.dai();
        MockToken usdc = e.usdc();
        LenderFixed lender = e.fixedLender();

        dai.mint(address(this), 1e18);
        dai.approve(address(lender), 1e18);
        lender.deposit(1e18);
        usdc.mint(address(lender), 1_000_000e6);

        bool overBorrowed;
        try lender.borrow(1_000_000e6) returns (uint256) {
            overBorrowed = true;
        } catch {}
        assertFalse(overBorrowed, "fair oracle allowed 1_000_000 USDC");
        assertEq(usdc.balanceOf(address(this)), 0, "control leaked USDC");

        uint256 out = lender.borrow(1e6);
        assertEq(out, 1e6, "1 USDC borrow");
        assertEq(usdc.balanceOf(address(this)), 1e6, "received 1 USDC");
        assertEq(e.fixedOracle().getUSDValue(address(usdc), 1e6), 1e18, "1 USDC is 1e18 USD");
        assertEq(e.fixedOracle().getUSDValue(address(dai), 1e18), 1e18, "1 DAI is 1e18 USD");
    }
}
