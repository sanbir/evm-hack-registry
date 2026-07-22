// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27233-c-01-collateral-double-spend-post-liquidation-is-possible-pa.sol";

contract LuminCollateralDoubleSpendTest is Test {
    function test_CollateralDoubleSpendPostLiquidation() public {
        Exploit e = new Exploit();
        e.run();

        // Bob recovered his already-seized 500 collateral a second time.
        assertEq(e.bobRecoveredAfterSeize(), 500);

        // Carol's honest claim now exceeds the pool's real token balance by
        // exactly the double-spent amount — the pool is insolvent.
        assertEq(e.carolClaim(), 1000);
        assertLt(e.poolBalanceAfterBobWithdraw(), e.carolClaim());
        assertEq(e.carolClaim() - e.poolBalanceAfterBobWithdraw(), 500);
    }

    /// @dev Control: WITHOUT a second liquidation, Bob cannot withdraw more
    ///      than he deposited — the double-spend only exists because the
    ///      Seize branch forgets to decrement depositAmount.
    function test_Control_NoLiquidation_NoDoubleSpend() public {
        MockToken token = new MockToken();
        AssetManager am = new AssetManager(token);
        Depositor bob = new Depositor(token, am);

        bob.deposit(500);
        // Bob never locks/never gets liquidated — withdraws exactly what he put in.
        bob.withdraw(500);
        assertEq(token.balanceOf(address(bob)), 500);

        // A second withdraw attempt now correctly reverts — no bug present
        // once his own deposit is honestly zeroed out.
        vm.expectRevert();
        bob.withdraw(1);
    }
}
