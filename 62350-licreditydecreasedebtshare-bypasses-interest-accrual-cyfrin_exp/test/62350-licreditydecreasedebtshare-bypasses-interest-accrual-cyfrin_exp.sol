// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Licredity
} from "./62350-licreditydecreasedebtshare-bypasses-interest-accrual-cyfrin.sol";

contract DecreaseDebtShareInterestBypassTest is Test {
    function test_decreaseDebtShare_skipsInterest() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.amountRepaid(), e.amountBorrowed(), "repaid == principal");
        assertGt(e.amountIfAccrued(), e.amountRepaid(), "accrued path costs more");
        assertGt(e.interestSkipped(), 0, "interest skipped");
        assertEq(e.lic().debtShareOf(e.positionId()), 0, "shares cleared");
    }

    /// @dev Control: calling unlock (accrual) before repay makes repayment cost more.
    function test_unlockThenRepay_chargesInterest() public {
        Licredity lic = new Licredity();
        uint256 id = lic.open();
        uint256 delta = 1e8 * 1e6;
        uint256 borrowed = lic.increaseDebtShare(id, delta, address(this));

        // accrue interest via unlock
        lic.unlock();

        uint256 due = lic.previewRepayWithAccrual(delta);
        // borrower must obtain the extra interest tokens to repay post-accrual
        // (mint via a second tiny position that we immediately abandon is overkill —
        //  force-credit the debt fungible by borrowing on a second position)
        uint256 id2 = lic.open();
        uint256 extra = due - borrowed;
        // mint at least `extra` more debt fungible to this address
        lic.increaseDebtShare(id2, extra, address(this));

        uint256 repaid = lic.decreaseDebtShare(id, delta, false);
        assertGt(repaid, borrowed, "interest charged after unlock");
        assertEq(repaid, due, "repaid matches accrued preview");
    }
}
