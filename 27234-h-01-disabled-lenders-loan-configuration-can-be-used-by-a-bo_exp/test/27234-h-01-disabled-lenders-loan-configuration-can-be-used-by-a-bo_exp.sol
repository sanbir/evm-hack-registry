// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27234-h-01-disabled-lenders-loan-configuration-can-be-used-by-a-bo.sol";

contract LuminDisabledLoanConfigTest is Test {
    function test_DisabledLoanConfigCanStillBeUsed() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.bobBorrowed(), 500);
        assertEq(e.aliceReclaimed(), 500);
    }

    /// @dev Control: the `availablePrincipal` cap itself DOES work correctly
    ///      (a borrow exceeding it reverts) — proving the bug is specifically
    ///      that `enabled` is ignored, not that every check is missing.
    function test_Control_ExceedsAvailablePrincipal_Reverts() public {
        MockToken token = new MockToken();
        LoanManager lm = new LoanManager(token);
        Actor alice = new Actor(token, lm);
        Actor bob = new Actor(token, lm);

        uint256 configId = alice.createLoanConfig(100);
        alice.disable(configId); // disabling has NO effect on borrowability (the bug)...

        vm.expectRevert(); // ...but the availablePrincipal cap is still enforced
        bob.borrow(configId, 101);
    }

    /// @dev Control: an ENABLED config is borrowed against exactly the same
    ///      way as a DISABLED one — the `enabled` flag has zero effect on
    ///      `createLoan`, which is precisely the bug.
    function test_Control_EnabledConfigBehavesIdentically() public {
        MockToken token = new MockToken();
        LoanManager lm = new LoanManager(token);
        Actor alice = new Actor(token, lm);
        Actor bob = new Actor(token, lm);

        uint256 configId = alice.createLoanConfig(1000);
        // config stays enabled (no disable() call) — Bob borrows 500 just as
        // easily as in the main exploit, where the config was disabled.
        bob.borrow(configId, 500);
        assertEq(token.balanceOf(address(bob)), 500);
    }
}
