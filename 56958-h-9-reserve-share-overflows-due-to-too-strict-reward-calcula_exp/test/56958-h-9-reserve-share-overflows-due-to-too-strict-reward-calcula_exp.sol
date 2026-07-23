// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./56958-h-9-reserve-share-overflows-due-to-too-strict-reward-calcula.sol";

contract ReserveShareOverflowTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.overflowDoS(), "DoS via overflow");
        assertGt(e.finalShares(), 1e40, "shares inflated");
    }
}
