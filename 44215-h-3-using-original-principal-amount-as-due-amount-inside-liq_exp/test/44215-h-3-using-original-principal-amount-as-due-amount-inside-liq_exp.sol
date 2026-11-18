// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit, LenderGroupFixed, MockToken} from "./44215-h-3-using-original-principal-amount-as-due-amount-inside-liq.sol";
contract Finding44215Test is Test {
    function test_original_principal_traps_80() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.borrowReverted());
        assertEq(e.avail(), 50e18);
        assertEq(e.leftInGroup(), 80e18);
        assertEq(e.group().totalPrincipalTokensRepaid(), 180e18);
        assertEq(e.group().tokenDifferenceFromLiquidations(), -50e18);
    }
    function test_control_remaining_principal_releases_all_130() public {
        MockToken token = new MockToken();
        LenderGroupFixed g = new LenderGroupFixed(token);
        token.mint(address(this), 130e18);
        token.approve(address(g), type(uint256).max);
        g.openLoan(1, 100e18);
        g.repayLoanCallback(1, 80e18);
        g.liquidateDefaultedLoanWithIncentive(1, 50e18);
        assertEq(g.availableToWithdraw(), 130e18);
        assertEq(g.totalPrincipalTokensRepaid(), 100e18);
    }
}
