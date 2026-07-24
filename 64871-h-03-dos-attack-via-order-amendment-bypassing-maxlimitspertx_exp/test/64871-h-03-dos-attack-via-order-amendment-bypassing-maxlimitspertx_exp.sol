// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64871-h-03-dos-attack-via-order-amendment-bypassing-maxlimitspertx.sol";

contract AmendBypassTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.bypassWorked(), "amend flood bypasses maxLimitsPerTx");
        assertEq(e.amendsDone(), 50, "50 free amends");
    }

    function test_control_post_limit_enforced() public {
        CLOB c = new CLOB(1);
        c.postLimitOrder(address(this), 1, 1);
        vm.expectRevert(CLOB.LimitsPlacedExceedsMax.selector);
        c.postLimitOrder(address(this), 2, 1);
    }
}
