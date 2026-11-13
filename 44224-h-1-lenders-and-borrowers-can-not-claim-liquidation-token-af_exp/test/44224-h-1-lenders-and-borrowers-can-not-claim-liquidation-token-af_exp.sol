// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Aero, LoanFixed} from "./44224-h-1-lenders-and-borrowers-can-not-claim-liquidation-token-af.sol";

contract Finding44224Test is Test {
    function test_exploit_locks_liquidation_proceeds() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.claimReverted(), "reverted");
        assertEq(e.aero().balanceOf(address(e.loan())), 100 ether, "locked");
        assertEq(e.aero().balanceOf(e.lender()), 0, "lender");
    }

    function test_control_decimals_without_ownerOf_pays_the_lender() public {
        Aero aero = new Aero();
        address lender = address(0xBEEF);
        LoanFixed loan = new LoanFixed(aero, lender);
        aero.mint(address(this), 100 ether);
        aero.approve(address(loan), 100 ether);
        loan.fund();
        loan.claimCollateralAsLender(0);
        assertEq(aero.balanceOf(lender), 100 ether, "paid");
        assertEq(aero.balanceOf(address(loan)), 0, "empty");
        assertTrue(loan.claimed(), "claimed");
    }
}
