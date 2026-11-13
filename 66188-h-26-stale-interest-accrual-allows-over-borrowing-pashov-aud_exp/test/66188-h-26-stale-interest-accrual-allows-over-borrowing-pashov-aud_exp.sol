// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./66188-h-26-stale-interest-accrual-allows-over-borrowing-pashov-aud.sol";

contract Finding66188Test is Test {
    function test_exploit_borrows_against_stale_debt() public {
        Exploit e = new Exploit();
        e.run();
        assertGt(e.debtAfter(), 100 ether, "over");
        assertEq(e.asset().balanceOf(address(e)), 1 ether, "borrowed");
    }

    function test_control_accrual_before_the_check_reverts() public {
        Exploit e = new Exploit();
        e.runFixed();
        assertEq(e.asset().balanceOf(address(e)), 0, "none");
        assertGt(e.pool().getPositionDebt(address(e)), 100 ether, "accrued");
    }
}
