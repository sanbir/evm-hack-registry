// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, LendingPool, DebtTokenFixed} from
    "./66165-h-03-debttoken-total-supply-is-inflated-pashov-audit-group-n.sol";

contract Finding66165Test is Test {
    function test_exploit_supply_inflation_blocks_the_next_borrow() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.inflated(), 450 ether, "inflated");
        assertEq(e.trueDebt(), 250 ether, "true");
        assertTrue(e.bobBlocked(), "blocked");
    }

    function test_control_scaled_principal_stays_under_the_cap() public {
        LendingPool pool = new LendingPool();
        DebtTokenFixed debt = new DebtTokenFixed(pool);
        pool.bind(debt);

        assertTrue(pool.borrow(address(0xA11CE), 100 ether), "first");
        pool.accrue();
        assertTrue(pool.borrow(address(0xA11CE), 50 ether), "second");
        assertEq(debt.totalSupply(), 250 ether, "supply");
        assertTrue(pool.borrow(address(0xB0B), 40 ether), "bob");
        assertEq(pool.actualDebt(), 290 ether, "true after bob");
    }
}
