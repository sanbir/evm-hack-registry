// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63177-h-11-takers-pay-significantly-higher-fees-than-expected-due.sol";

contract AmmplifySegmentBorrowTest is Test {
    function test_exploit_splitInflatesBorrowBase() public {
        Exploit e = new Exploit();
        e.run();
        assertGt(e.splitX() + e.splitY(), e.fullX() + e.fullY());
        assertGt(e.feeSplitX(), e.feeFullX());
    }
}
