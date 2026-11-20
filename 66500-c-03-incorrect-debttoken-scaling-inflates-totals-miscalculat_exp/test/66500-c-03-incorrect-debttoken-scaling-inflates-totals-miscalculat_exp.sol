// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, DebtTokenFixed} from
    "./66500-c-03-incorrect-debttoken-scaling-inflates-totals-miscalculat.sol";

contract Finding66500Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_second_borrow_is_doubled() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.debt().lastSupply(), 400 ether, "reports 400");
        assertEq(e.marker().balanceOf(SINK), 100 ether, "100 extra");
    }

    function test_control_scales_the_second_borrow() public {
        DebtTokenFixed debt = new DebtTokenFixed();
        debt.borrow(100 ether);
        debt.setIndex(2 ether);
        debt.borrow(100 ether);
        assertEq(debt.totalSupply(), 300 ether, "200 of old debt plus the new 100");
    }
}
