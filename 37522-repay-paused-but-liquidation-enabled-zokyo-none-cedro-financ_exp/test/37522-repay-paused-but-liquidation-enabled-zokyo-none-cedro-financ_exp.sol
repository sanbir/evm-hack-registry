// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Borrower,
    Exploit,
    Pool,
    Token
} from "./37522-repay-paused-but-liquidation-enabled-zokyo-none-cedro-financ.sol";

contract Finding37522Test is Test {
    bytes32 internal constant ID = bytes32("loan");

    function test_exploit_repay_reverts_and_collateral_is_seized() public {
        Exploit e = new Exploit();
        e.run();

        assertFalse(e.repayOk(), "borrower could not repay");
        assertEq(e.seized(), 99 ether, "liquidator seized 99 collateral");
        assertEq(e.col().balanceOf(address(e)), 99 ether, "99 collateral paid to the liquidator");
        assertEq(e.pool().collateralOf(e.ID()), 1 ether, "1 collateral left on the position");
        assertEq(e.debtToken().balanceOf(address(e.borrower())), 20 ether, "the saving 20 debt was never spent");
    }

    function test_control_repay_saves_the_collateral() public {
        Token col = new Token();
        Token debt = new Token();
        Pool pool = new Pool(col, debt);
        Borrower borrower = new Borrower(debt, pool);

        pool.seed(ID, address(borrower), 100 ether, 90 ether);
        borrower.fundAndApprove(20 ether);
        assertTrue(borrower.tryRepay(ID, 20 ether), "repay succeeds while repayPause is false");

        assertEq(pool.debtOf(ID), 70 ether, "debt fell to 70");
        bool liquidated;
        try pool.liquidate(ID) returns (uint256) {
            liquidated = true;
        } catch {
            liquidated = false;
        }
        assertFalse(liquidated, "the position is no longer underwater");
        assertEq(col.balanceOf(address(pool)), 100 ether, "all 100 collateral stayed in the pool");
        assertEq(col.balanceOf(address(this)), 0, "liquidator received nothing");
        assertEq(debt.balanceOf(address(borrower)), 0, "the 20 debt was spent on the repay");
    }
}
