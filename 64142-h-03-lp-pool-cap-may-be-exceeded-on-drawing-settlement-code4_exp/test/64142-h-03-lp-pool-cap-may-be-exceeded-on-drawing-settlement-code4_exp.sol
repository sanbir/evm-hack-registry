// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64142-h-03-lp-pool-cap-may-be-exceeded-on-drawing-settlement-code4.sol";

contract MegapotPoolCapTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertGt(e.jackpot().lastNewLPValue(), e.GOV_CAP(), "cap exceeded");
        assertEq(e.jackpot().lastNewLPValue(), e.GOV_CAP() + e.EARNINGS(), "earnings added unchecked");
    }
}
