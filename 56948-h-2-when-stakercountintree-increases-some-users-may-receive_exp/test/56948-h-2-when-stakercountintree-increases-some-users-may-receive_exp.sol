// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./56948-h-2-when-stakercountintree-increases-some-users-may-receive.sol";

/* LayerEdge — H-2 missed T3→T2 promotion underpays interest (Sherlock 2025-05) */
contract PoC_56948 is Test {
    function test_missedPromotionUnderpaysInterest() public {
        Exploit e = new Exploit();
        e.run();

        // Victim stuck on T3, receives 20% instead of 35% for a year
        assertEq(e.victimInterest(), 3000e18 * 20 / 100);
        assertEq(e.underpay(), 3000e18 * 15 / 100);
        assertEq(e.token().balanceOf(address(e)), e.underpay());
        assertEq(e.staking().getTier(e.victim()), 3);
    }
}
