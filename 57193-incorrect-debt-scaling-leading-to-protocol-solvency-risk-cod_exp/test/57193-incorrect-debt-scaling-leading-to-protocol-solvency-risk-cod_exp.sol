// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, DebtToken, LendingPool, Cash, RayMath} from
    "./57193-incorrect-debt-scaling-leading-to-protocol-solvency-risk-cod.sol";

contract Finding57193Test is Test {
    function test_exploit_forgives_accrued_interest() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.debtBefore(), 121 ether, "debt before");
        assertEq(e.paid(), 110 ether, "paid");
        assertEq(e.debtAfter(), 0, "debt after");
        assertEq(e.shortfall(), 11 ether, "shortfall");
        assertEq(e.cash().balanceOf(e.BORROWER()), 11 ether, "kept");
        assertEq(e.cash().balanceOf(address(e)), 110 ether, "reserve");
    }

    function test_control_scaled_burn_leaves_the_interest() public {
        LendingPool pool = new LendingPool();
        Cash cash = new Cash();
        DebtToken debt = new DebtToken(pool, address(this));
        address borrower = address(uint160(0xB0B0));
        uint256 ray = 1e27;
        uint256 index = ray * 11 / 10;

        pool.setNormalizedDebt(ray);
        debt.mint(borrower, 110 ether, ray);
        pool.setNormalizedDebt(index);
        assertEq(debt.balanceOf(borrower), 121 ether, "owed");

        uint256 amountScaled = RayMath.rayDiv(110 ether, index);
        uint256 scaledBefore = debt.scaledBalance(borrower);
        // The fix burns amountScaled (100) rather than the unscaled 110.
        assertEq(amountScaled, 100 ether, "scaled repay");
        assertEq(scaledBefore - amountScaled, 10 ether, "scaled left");
        uint256 fairDebt = RayMath.rayMul(scaledBefore - amountScaled, index);
        assertEq(fairDebt, 11 ether, "interest remains owed");
    }
}
