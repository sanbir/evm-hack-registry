// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58596-precision-truncation-on-stake-may-lead-to-improper-accountin.sol";

contract KinetiqPrecisionTruncationTest is Test {
    function test_exploit_truncationInsolvency() public {
        Exploit e = new Exploit();
        e.run{value: e.STAKE_AMOUNT()}();

        assertTrue(e.unstakeFailed());
        assertEq(e.lostDust(), e.DUST());
        assertEq(e.l1Credited(), e.TRUNCATED());
        // After partial redeem of truncated quantum, dust shares remain unbacked.
        assertEq(e.manager().shares(address(e.user())), e.DUST());
        assertEq(e.l1().credited(), 0);
    }

    function test_control_alignedStakeFullyRedeemable() public {
        L1Hype l1 = new L1Hype();
        StakingManager mgr = new StakingManager(address(l1));
        User u = new User(mgr);
        uint256 amt = 1e10; // exactly 1 quantum
        u.doStake{value: amt}();
        assertEq(l1.credited(), amt);
        u.doUnstake(amt);
        assertEq(mgr.shares(address(u)), 0);
        assertEq(l1.credited(), 0);
    }
}
