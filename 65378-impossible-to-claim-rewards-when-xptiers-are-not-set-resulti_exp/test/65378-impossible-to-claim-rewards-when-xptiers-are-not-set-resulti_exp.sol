// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65378-impossible-to-claim-rewards-when-xptiers-are-not-set-resulti.sol";

contract XPTiersLockTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.tok().balanceOf(address(e.sm())), e.FEE(), "prize locked");
        assertEq(e.session().userXP(e.GAME_ID(), address(e.player())), 0, "zero xp");
    }
}
