// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63176-h-10-takers-can-pay-significantly-less-fees-with-makers-losi.sol";

contract AmmplifySubtreeBorrowTest is Test {
    function test_exploit_parentChargeIgnoresChildBorrow() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.buggyPaid(), 418e18);
        assertGt(e.correctPaid(), e.buggyPaid() * 40);
    }
}
