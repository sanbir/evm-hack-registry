// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./26974-h-06-users-may-be-forced-into-long-lock-times-to-be-able-to.sol";

/*//////////////////////////////////////////////////////////////
    Canto (veRWA) — VotingEscrow.delegate() forces a 5-year lock extension
    just to undelegate back to yourself (H-06, #26974)

    delegate() requires `toLocked.end >= fromLocked.end`, comparing the
    DELEGATEE's lock to the delegatee-you-are-moving-away-from's lock. Since
    VotingEscrow always resets a lock's duration to a fixed 5 years on every
    action, two locks created even one second apart have DIFFERENT absolute
    unlock times forever. A user who delegates to a lock created slightly
    later than their own can never undelegate back to themselves without
    extending their own lock by up to the full 5-year LOCKTIME.

    - test_exploit: drives the cheatcode-free Exploit end to end (funding +
      seeding Bob/Dave via `vm.deal` + `seed()`, then bumping Dave's lock end by
      one week via `vm.store` — mirrors the Playground's `setup.steps`, since
      real calendar time cannot elapse inside a single-timestamp `run()`), then
      re-asserts the stuck-delegation harm.
    - test_realTimeGapReproduction: standalone rebuild using a REAL elapsed
      second between Bob's and Dave's `createLock` calls (via `vm.warp`) —
      independent proof the bug is real, not an artifact of the vm.store
      shortcut above.
    - test_control_sameEpoch_canUndelegate: control — when both locks are
      created in the exact same epoch (so `end`s are equal), undelegating back
      to yourself works fine, isolating the lock-time MISMATCH as the root
      cause.
//////////////////////////////////////////////////////////////*/
contract VotingEscrowDelegateLockTimeTest is Test {
    // `locked`'s base slot is NOT 8: the giant fixed-size array
    // `Point[1e18] public pointHistory` (slot 4) reserves 3 storage slots per
    // element (bias+slope pack into 1 slot, ts and blk each take their own),
    // i.e. 3e18 contiguous slots, before the next variable's slot is assigned.
    // Layout: name(0) symbol(1) decimals(2) globalEpoch(3) pointHistory(4..4+3e18-1)
    // userPointHistory(4+3e18) userPointEpoch(4+3e18+1) slopeChanges(4+3e18+2)
    // locked(4+3e18+3) = 3e18+7.
    uint256 internal constant LOCKED_BASE_SLOT = 3_000_000_000_000_000_007;

    function _lockedEndSlot(address user) internal pure returns (bytes32) {
        bytes32 base = keccak256(abi.encode(user, LOCKED_BASE_SLOT)); // locked[user]
        return bytes32(uint256(base) + 1); // LockedBalance.end is field #1
    }

    /// @notice HARM via the self-contained Exploit.
    function test_exploit() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 2 ether);
        e.seed();

        // Bump Dave's unlock time by one WEEK — representing Dave having
        // locked one epoch later than Bob (real elapsed time a cheatcode-free
        // run() cannot itself produce).
        uint256 daveEnd = e.ve().lockEnd(address(e.dave()));
        vm.store(address(e.ve()), _lockedEndSlot(address(e.dave())), bytes32(daveEnd + 7 days));

        e.run();

        // Re-assert independently from the driver: Bob is still delegated to
        // Dave and could not reclaim his own voting power.
        (,,, address bobDelegatee) = e.ve().locked(address(e.bob()));
        assertEq(bobDelegatee, address(e.dave()), "bob's power is still stuck with dave");
    }

    /// @notice Standalone rebuild with a REAL elapsed second between the two
    ///         createLock calls — no storage shortcuts at all.
    function test_realTimeGapReproduction() public {
        VotingEscrow ve = new VotingEscrow("veCANTO", "veCANTO");

        address bob = makeAddr("bob");
        address dave = makeAddr("dave");
        vm.deal(bob, 1 ether);
        vm.deal(dave, 1 ether);

        vm.prank(bob);
        ve.createLock{value: 1 ether}(1 ether);

        // Real elapsed time: Dave locks 8 days later than Bob (more than one
        // WEEK, so both locks land in different weekly-floored epochs).
        vm.warp(block.timestamp + 8 days);
        vm.prank(dave);
        ve.createLock{value: 1 ether}(1 ether);

        uint256 bobEnd = ve.lockEnd(bob);
        uint256 daveEnd = ve.lockEnd(dave);
        assertGt(daveEnd, bobEnd, "dave's lock, created later, unlocks later");

        // Bob delegates to Dave — allowed, Dave's lock is longer.
        vm.prank(bob);
        ve.delegate(dave);
        (,,, address delegatee) = ve.locked(bob);
        assertEq(delegatee, dave, "bob delegated to dave");

        // HARM: Bob cannot undelegate back to himself.
        vm.prank(bob);
        vm.expectRevert(bytes("Only delegate to longer lock"));
        ve.delegate(bob);

        (,,, address stillDelegatee) = ve.locked(bob);
        assertEq(stillDelegatee, dave, "bob's voting power remains stuck with dave");
    }

    /// @notice Control: when both locks are created in the exact same
    ///         instant (equal unlock times), undelegating back to yourself
    ///         works fine — isolating the lock-time MISMATCH, not delegation
    ///         itself, as the root cause.
    function test_control_sameEpoch_canUndelegate() public {
        VotingEscrow ve = new VotingEscrow("veCANTO", "veCANTO");

        address bob = makeAddr("bob");
        address dave = makeAddr("dave");
        vm.deal(bob, 1 ether);
        vm.deal(dave, 1 ether);

        vm.prank(bob);
        ve.createLock{value: 1 ether}(1 ether);
        vm.prank(dave);
        ve.createLock{value: 1 ether}(1 ether); // same block/timestamp -> identical end

        assertEq(ve.lockEnd(bob), ve.lockEnd(dave), "identical unlock times");

        vm.prank(bob);
        ve.delegate(dave);

        // Undelegating back to self succeeds: toLocked.end (bob's own) equals
        // fromLocked.end (dave's) exactly, satisfying `>=`.
        vm.prank(bob);
        ve.delegate(bob);

        (,,, address delegatee) = ve.locked(bob);
        assertEq(delegatee, bob, "bob successfully reclaimed his own voting power");
    }
}
