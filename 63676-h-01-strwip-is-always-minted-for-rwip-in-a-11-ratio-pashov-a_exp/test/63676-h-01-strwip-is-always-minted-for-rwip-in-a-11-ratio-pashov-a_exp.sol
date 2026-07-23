// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63676-h-01-strwip-is-always-minted-for-rwip-in-a-11-ratio-pashov-a.sol";

contract AriaStRWIPOneToOneTest is Test {
    function test_bob_steals_rewards_via_one_to_one_mint() public {
        Exploit e = new Exploit();
        e.run();

        assertGt(e.bobProfit(), 0, "bob profit");
        assertGe(e.bobProfit(), 200e18, "substantial steal");
        assertLt(e.aliceFinal(), 1100e18, "alice underpaid");
        assertGt(e.rwip().balanceOf(address(e)), 1000e18, "bob above principal");
    }
}
