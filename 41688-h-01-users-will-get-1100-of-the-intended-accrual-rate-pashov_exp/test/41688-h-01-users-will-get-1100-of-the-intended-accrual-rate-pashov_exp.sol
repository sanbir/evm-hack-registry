// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, XpToken, DyadXPv2Fixed} from
    "./41688-h-01-users-will-get-1100-of-the-intended-accrual-rate-pashov.sol";

contract Finding41688Test is Test {
    function test_baseAccrualPaysOneHundredth() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paid(), 10_000_000 ether, "credited XP");
        assertEq(e.xp().balanceOf(address(e)), 10_000_000 ether, "xp balance");
        assertEq(block.timestamp, 1, "model clock");
    }

    function test_control_scale1e9_doesNotHitTheBuggyCredit() public {
        XpToken xp = new XpToken();
        DyadXPv2Fixed book = new DyadXPv2Fixed(xp);
        book.seed(1, address(this), 1 ether);
        uint256 paid = book.accrue(1);
        assertEq(paid, 1_000_000_000 ether, "documented accrual");
        assertTrue(paid != 10_000_000 ether, "control must not hit the buggy credit");
        assertEq(xp.balanceOf(address(this)), 1_000_000_000 ether, "fair balance");
    }
}
