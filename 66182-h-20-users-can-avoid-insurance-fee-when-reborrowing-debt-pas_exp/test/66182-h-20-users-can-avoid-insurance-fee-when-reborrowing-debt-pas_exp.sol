// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, DebtToken, InsuranceVault, LendingPool, Borrower} from
    "./66182-h-20-users-can-avoid-insurance-fee-when-reborrowing-debt-pas.sol";

contract Finding66182Test is Test {
    function test_exploit_reborrow_skips_insurance_fee() public {
        Exploit e = new Exploit();
        e.run();

        (, , bool flag) = e.pool().position();
        assertTrue(flag, "still insured");
        assertEq(e.pool().feesCharged(), 1, "one fee");
        assertEq(e.token().balanceOf(address(e.insurance())), 100 ether, "insurance holds 100");
        assertEq(e.token().balanceOf(address(e.borrower())), 10_000 ether, "borrower holds the new principal");
    }

    function test_control_full_repay_clears_the_flag() public {
        DebtToken token = new DebtToken();
        InsuranceVault insurance = new InsuranceVault();
        LendingPool pool = new LendingPool(token, address(insurance), true);
        Borrower borrower = new Borrower();
        token.mint(address(pool), 20_000 ether);
        token.mint(address(borrower), 200 ether);
        borrower.approve(token, address(pool), type(uint256).max);

        borrower.borrow(pool, 10_000 ether);
        borrower.repay(pool, 10_000 ether);
        (, , bool flag) = pool.position();
        assertFalse(flag, "flag cleared");

        borrower.borrow(pool, 10_000 ether);
        assertEq(pool.feesCharged(), 2, "both fees");
        assertEq(token.balanceOf(address(insurance)), 200 ether, "insurance holds 200");
    }
}
