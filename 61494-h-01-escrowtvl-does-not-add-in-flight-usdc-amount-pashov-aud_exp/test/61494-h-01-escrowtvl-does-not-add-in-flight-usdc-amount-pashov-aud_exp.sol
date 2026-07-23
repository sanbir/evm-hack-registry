// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./61494-h-01-escrowtvl-does-not-add-in-flight-usdc-amount-pashov-aud.sol";

contract Blueberry61494Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.tvlBuggyDuringBridge(), 500e18, "understated tvl");
        assertEq(e.tvlCorrectDuringBridge(), 1000e18, "correct includes in-flight");
        assertEq(e.attackerShares(), 1000e18, "2x shares");
        assertEq(e.attackerProfit(), 250e6, "250 USDC profit");
    }
}
