// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, USD, LoanManager} from "./61079-wrong-borrow-balance-calculation-in-the-getloanliquidity-fun.sol";

contract Finding61079Test is Test {
    function test_exploit_shrunk_debt_lets_the_borrower_draw_more() public {
        vm.warp(365 days + 1000);
        Exploit e = new Exploit();
        e.run();

        assertEq(e.wrongDebt(), 50 ether, "view shows 50");
        assertEq(e.trueDebt(), 200 ether, "real debt is 200");
        assertEq(e.drawn(), 80 ether, "drew 80");
        assertTrue(e.liquidationReverted(), "liquidation reverted");
        assertEq(e.usd().balanceOf(address(e)), 80 ether, "borrower holds 80");
        assertEq(e.loans().collateralValue(address(e)), 150 ether, "collateral not seized");
    }

    function test_control_correct_index_order_blocks_the_draw() public {
        vm.warp(365 days + 1000);
        USD usd = new USD();
        LoanManager fixedLoans = new LoanManager(usd, true);
        usd.mint(address(fixedLoans), 200 ether);
        fixedLoans.open(address(this), 100 ether, 150 ether, 1e18);

        assertEq(fixedLoans.debtOf(address(this)), 200 ether, "debt is 200");
        vm.expectRevert(bytes("over"));
        fixedLoans.borrow(80 ether);

        assertEq(usd.balanceOf(address(this)), 0, "nothing drawn");
        assertEq(usd.balanceOf(address(fixedLoans)), 200 ether, "pool intact");
    }
}
