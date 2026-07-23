// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./50064-h-01-adversary-can-win-proposals-with-voting-power-as-low-as.sol";

/* IQ AI H-01 — quorum 4% instead of intended 25% (Code4rena 2025-01) */
contract PoC_50064 is Test {
    function test_attackLowQuorum() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.agent().taken());
        assertEq(e.quorumAtVote(), (e.SUPPLY() * 4) / 100);
        assertEq(e.attackerVotes(), e.quorumAtVote());
        // Would fail a true 25% quorum
        assertLt(e.attackerVotes(), (e.SUPPLY() * 25) / 100);
    }
}
