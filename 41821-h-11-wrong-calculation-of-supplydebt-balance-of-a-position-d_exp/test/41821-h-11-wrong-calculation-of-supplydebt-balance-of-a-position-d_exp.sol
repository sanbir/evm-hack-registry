// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, PoolFixed, Supplier} from
    "./41821-h-11-wrong-calculation-of-supplydebt-balance-of-a-position-d.sol";

contract Finding41821Test is Test {
    function test_exploit_max_repay_clears_a_2_token_debt_for_1_token() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.pool().trueDebtBeforePay(), 2 ether, "true debt was 2");
        assertEq(e.pool().reportedDebt(), 1 ether, "reported the share");
        assertEq(e.pool().paid(), 1 ether, "pulled 1");
        assertEq(e.pool().debtSharesOf(address(e)), 0, "debt flag cleared");
        assertEq(e.kept(), 1 ether, "borrower kept 1");
        assertEq(e.token().balanceOf(address(e.pool())), 3 ether, "supplier is short 1 of 4");
    }

    function test_control_asset_debt_makes_max_repay_return_the_2() public {
        Token token = new Token();
        PoolFixed pool = new PoolFixed(token);
        Supplier supplier = new Supplier();
        token.mint(address(supplier), 4 ether);
        supplier.supplyFixed(pool, token, 4 ether);
        pool.borrow(2 ether);
        token.approve(address(pool), type(uint256).max);
        pool.repay(type(uint256).max);

        assertEq(pool.paid(), 2 ether, "paid the asset debt");
        assertEq(pool.debtShares(address(this)), 0, "cleared");
        assertEq(token.balanceOf(address(this)), 0, "borrower kept nothing");
        assertEq(token.balanceOf(address(pool)), 4 ether, "supplier whole");
    }
}
