// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65377-impossible-to-claim-rewards-when-ranked-rewards-or-number-of.sol";

contract RankedRewardsLockTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.tok().balanceOf(address(e.sm())), e.FEE(), "locked in SM");
        assertEq(e.tok().balanceOf(address(e.player())), 0, "player unpaid");
    }
}
