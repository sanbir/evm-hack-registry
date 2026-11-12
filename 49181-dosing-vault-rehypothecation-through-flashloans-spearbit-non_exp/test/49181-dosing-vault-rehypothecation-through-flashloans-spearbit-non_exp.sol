// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Vault,
    ControlAToken,
    MockToken
} from "./49181-dosing-vault-rehypothecation-through-flashloans-spearbit-non.sol";

contract FlashRehypothecationTest is Test {
    uint256 internal constant AMOUNT = 1000 ether;

    function test_exploit_repaymentLeavesTheVaultEmpty() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.withdrawBlocked(), "withdraw blocked");
        assertEq(e.vaultLeft(), 0, "vault");
        assertEq(e.stuckOnAToken(), AMOUNT, "stuck");
        assertEq(e.accounted(), AMOUNT, "accounted");
        assertEq(e.controlPaid(), AMOUNT, "control paid");
        assertEq(e.token().balanceOf(address(e.aToken())), AMOUNT, "aToken balance");
        assertEq(e.token().balanceOf(address(e.controlVault())), 0, "control vault");
    }

    function test_control_flashPathIsBlockedAndDepositorWithdraws() public {
        MockToken token = new MockToken();
        Vault vault = new Vault(address(token));
        ControlAToken gate = new ControlAToken();
        token.mint(address(this), AMOUNT);
        token.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT);

        vm.expectRevert(bytes("flash blocked"));
        gate.transferUnderlyingTo(address(this), AMOUNT);

        vault.withdraw(AMOUNT);
        assertEq(token.balanceOf(address(this)), AMOUNT, "depositor received N");
        assertEq(token.balanceOf(address(vault)), 0, "vault emptied by the depositor");
    }
}
