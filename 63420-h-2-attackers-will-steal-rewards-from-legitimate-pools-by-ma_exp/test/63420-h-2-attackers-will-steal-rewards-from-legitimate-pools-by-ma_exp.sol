// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {Exploit, DCAToken} from "./63420-h-2-attackers-will-steal-rewards-from-legitimate-pools-by-ma.sol";

contract SuperDCAGaugeRewardTheftTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_unlistedDuplicatePoolStealsPerTokenReward() public {
        Exploit e = new Exploit();
        e.run();

        // The attacker's UNLISTED duplicate pool drained USDC's shared per-token
        // reward bucket and captured the community share (half of 1000e18).
        assertEq(e.communityShare(), 500 ether, "community share");
        assertEq(e.attackerStolen(), 500 ether, "attacker stole the community share");

        // The legitimately-listed pool received nothing for USDC.
        assertEq(e.legitPot(), 0, "legit pool received nothing");
        assertLt(e.legitPot(), e.attackerStolen(), "legit pool got less than the attacker");

        // Real DCA token delta: the stolen reward physically sits at the attacker EOA.
        DCAToken dca = DCAToken(e.dcaAddr());
        assertEq(dca.balanceOf(ATTACKER), 500 ether, "stolen DCA at attacker EOA");
    }

    function test_control_fixedGaugeBlocksUnlistedPool() public {
        // Same scenario against the FIXED gauge (pool-legitimacy check present).
        Exploit e = new Exploit();
        e.runFixedControl();

        // The attacker's unlisted pool is a no-op: it steals nothing.
        assertEq(e.fixedAttackerStolen(), 0, "fixed: attacker steals nothing");

        // The legitimately-listed pool receives the full community share.
        assertEq(e.fixedLegitPot(), 500 ether, "fixed: legit pool receives community share");
        assertGt(e.fixedLegitPot(), e.fixedAttackerStolen(), "fixed: legit pool out-earns attacker");
    }
}
