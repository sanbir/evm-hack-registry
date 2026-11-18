// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, LendingPool, LendingPoolFixed} from "./66362-h-21-users-may-be-forced-to-pay-more-interest-pashov-audit-g.sol";

contract Finding66183Test is Test {
    function test_exploit_dust_repay_forces_1210() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.dustDebt(), 1100 ether, "debt unchanged at 1100");
        assertEq(e.finalDebt(), 1210 ether, "later debt is 1210");
        assertEq(e.fairDebt(), 1200 ether, "fair debt is 1200");
        assertEq(e.poolTaken(), 1210 ether + 1, "pool took the extra");
    }

    function test_control_without_dust_repay_debt_is_1200() public {
        Token asset = new Token("RA");
        LendingPool pool = new LendingPool(asset);
        asset.mint(address(pool), 1000 ether);
        pool.borrow(address(this), 1000 ether);
        pool.accrue(12 * 1e26);
        assertEq(pool.debtOf(address(this)), 1200 ether, "no dust repay, debt is 1200");
    }

    function test_control_minimum_repay_rejects_one_wei() public {
        Token asset = new Token("RA");
        LendingPoolFixed pool = new LendingPoolFixed(asset);
        asset.mint(address(pool), 1000 ether);
        pool.borrow(address(this), 1000 ether);
        pool.accrue(11 * 1e26);
        vm.expectRevert(bytes("min repay"));
        pool.repayOnBehalf(address(this), 1);
        assertEq(pool.rawBalance(address(this)), 1000 ether, "raw principal stays 1000");
    }
}
