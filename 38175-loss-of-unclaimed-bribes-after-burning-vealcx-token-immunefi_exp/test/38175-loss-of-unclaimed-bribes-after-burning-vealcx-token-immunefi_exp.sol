// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38175-loss-of-unclaimed-bribes-after-burning-vealcx-token-immunefi.sol";

contract BribeFrozenAfterWithdrawTest is Test {
    /// @notice HARM: run() proves the 100k BAL bribe becomes permanently
    ///         unclaimable once the veALCX token is burned via withdraw().
    function test_exploit_bribesFrozenAfterBurn() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.bribe().balanceHeld(), 100_000 ether, "bribe funds should remain stuck in the Bribe contract");
        assertFalse(e.ve().isApprovedOrOwner(address(e), 1), "exploit contract should no longer own the burned token");
    }

    /// @notice Control: claiming the bribe BEFORE withdrawing works fine --
    ///         isolating that the bug is specifically "burn precedes bribe
    ///         claim", not "bribes are broken in general".
    function test_control_claimBeforeWithdrawSucceeds() public {
        MockBAL bal = new MockBAL();
        VotingEscrow ve = new VotingEscrow(1, address(this));
        Bribe bribe = new Bribe(ve, bal);

        bal.mint(address(bribe), 100_000 ether);
        bribe.notifyBribe(1, 100_000 ether);

        // Claim bribes FIRST, while still owner.
        bribe.getRewardForOwner(1, address(this));
        assertEq(bal.balanceOf(address(this)), 100_000 ether, "bribe should be received while still owner");
        assertEq(bribe.balanceHeld(), 0, "bribe contract should be drained");

        // Now withdraw is safe -- nothing left to lose.
        ve.withdraw(1);
        assertFalse(ve.isApprovedOrOwner(address(this), 1));
    }
}
