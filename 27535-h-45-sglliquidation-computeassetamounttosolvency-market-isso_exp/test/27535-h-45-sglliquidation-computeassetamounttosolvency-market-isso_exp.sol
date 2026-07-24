// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27535-h-45-sglliquidation-computeassetamounttosolvency-market-isso.sol";

contract FalseSolvencyTest is Test {
    function test_dust_share_allows_unbacked_borrow() public {
        Exploit exp = new Exploit();
        exp.run();
        assertEq(exp.realCollatAmount(), 0);
        assertGt(exp.borrowed(), 0);
    }
}
