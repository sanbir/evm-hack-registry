// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./57723-h-02-first-deposit-front-running-attack-pashov-audit-group-n.sol";

contract FirstDepositFrontrunTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.charlieShares(), 1, "charlie only 1 share");
        assertGe(e.aliceStolen0(), 1 ether, "alice extracted value");
        assertEq(e.burve().totalShares(), 1, "alice burned; charlie remains");
    }
}
