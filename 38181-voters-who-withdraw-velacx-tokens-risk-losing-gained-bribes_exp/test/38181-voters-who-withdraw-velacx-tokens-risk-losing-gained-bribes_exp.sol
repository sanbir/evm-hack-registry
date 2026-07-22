// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38181-voters-who-withdraw-velacx-tokens-risk-losing-gained-bribes.sol";

contract BribeFrozenAfterWithdrawSequenceTest is Test {
    /// @notice HARM: run() proves the 100k BAL bribe becomes permanently
    ///         unclaimable after the standard reset -> startCooldown ->
    ///         withdraw sequence burns the veALCX token.
    function test_exploit_bribesFrozenAfterWithdrawSequence() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.bribe().balanceHeld(), 100_000 ether, "bribe funds should remain stuck in the Bribe contract");
        assertFalse(e.ve().isApprovedOrOwner(address(e), 1), "exploit contract should no longer own the burned token");
    }

    /// @notice Control: claiming the bribe BEFORE running the withdrawal
    ///         sequence succeeds -- isolating that the bug is "burn precedes
    ///         bribe claim", not "bribes are broken in general".
    function test_control_claimBeforeWithdrawSequenceSucceeds() public {
        MockBAL bal = new MockBAL();
        VotingEscrow ve = new VotingEscrow(1, address(this));
        Bribe bribe = new Bribe(ve, bal);

        bal.mint(address(bribe), 100_000 ether);
        bribe.notifyBribe(1, 100_000 ether);

        // Claim bribes FIRST, before starting the withdrawal sequence.
        bribe.getRewardForOwner(1, address(this));
        assertEq(bal.balanceOf(address(this)), 100_000 ether, "bribe should be received while still owner");
        assertEq(bribe.balanceHeld(), 0, "bribe contract should be drained");

        // Now the full withdrawal sequence is safe -- nothing left to lose.
        ve.reset(1);
        ve.startCooldown(1);
        ve.withdraw(1);
        assertFalse(ve.isApprovedOrOwner(address(this), 1));
    }
}
