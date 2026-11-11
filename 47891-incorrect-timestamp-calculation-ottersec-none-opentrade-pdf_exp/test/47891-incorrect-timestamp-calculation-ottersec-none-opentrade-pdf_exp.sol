// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, LoanFixed, MockToken} from "./47891-incorrect-timestamp-calculation-ottersec-none-opentrade-pdf.sol";

contract IncorrectTimestampTest is Test {
    address internal constant LENDER = 0x0000000000000000000000000000000000000B0b;
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant PRINCIPAL = 1000 ether;

    function test_exploit_lateWindowUnlocksPrincipal() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), PRINCIPAL, "paid");
        assertEq(e.fairUnlock(), 0, "fair unlock");
        assertEq(e.buggyClose(), START + 26 days, "buggy close");
        assertEq(e.fairClose(), START + 23 days, "fair close");
        assertEq(e.token().balanceOf(LENDER), PRINCIPAL, "lender balance");
    }

    function test_control_correctedCloseRejectsTheSameRequest() public {
        MockToken token = new MockToken();
        LoanFixed loan = new LoanFixed(address(token), LENDER, START);
        token.mint(address(loan), PRINCIPAL);
        loan.openSchedule();

        assertEq(loan.earlyRedeemRequestClosingTimestamp(), START + 23 days, "corrected close");

        vm.expectRevert(bytes("early redeem closed"));
        loan.requestEarlyRedeem(START + 24 days);
        assertEq(token.balanceOf(LENDER), 0, "day-24 request unlocked funds");

        uint256 paid = loan.requestEarlyRedeem(START + 23 days);
        assertEq(paid, PRINCIPAL, "request on the corrected close was not paid");
        assertEq(token.balanceOf(LENDER), PRINCIPAL, "lender was not paid at the fair close");
    }
}
