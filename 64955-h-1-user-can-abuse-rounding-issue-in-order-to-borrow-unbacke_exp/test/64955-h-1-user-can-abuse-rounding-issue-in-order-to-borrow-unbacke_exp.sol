// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64955-h-1-user-can-abuse-rounding-issue-in-order-to-borrow-unbacke.sol";

contract MonolithRoundingUnbackedBorrowTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.borrowed(), 1e27, "borrowed 1e27");
        assertLt(e.realDebt(), 1e27 / 100, "debt deflated");
        assertGt(e.borrowed(), e.realDebt(), "unbacked");
    }
}
