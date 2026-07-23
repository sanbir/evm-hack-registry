// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65419-myriadctfexchangematchcrossmarketorders-allows-taker-to-rece.sol";

contract MyriadFreeYesTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.charliePaid(), 0, "taker paid zero");
        assertEq(e.charlieYes(), e.FILL(), "free YES");
        assertEq(e.stuckSurplus(), 20 ether, "20 stuck");
    }
}
