// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Token,
    VotingEscrowFixed
} from "./58018-h-07-inconsistent-rounding-of-lock-time-causes-voting-power.sol";

contract Finding58018Test is Test {
    function test_exploit_unrounded_power_outvotes() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.powerRounded(), 62_899_199, "rounded power");
        assertEq(e.powerUnrounded(), 63_072_000, "unrounded power");
        assertGt(e.powerUnrounded(), e.powerRounded(), "split power is larger");
        assertTrue(e.checkpointMissedSplitEnd(), "week checkpoint missed the split end");
        assertEq(e.gov().yesVotes(), 63_072_000, "yes votes");
        assertEq(e.gov().noVotes(), 62_899_199, "no votes");
        assertEq(e.reward().balanceOf(address(this)), 1_000 ether, "larger power took the prize");
        assertTrue(e.gov().finalized(), "vote passed");
    }

    function test_control_week_rounding_ties_the_vote() public {
        Token lock = new Token("Lock", "LOCK");
        VotingEscrowFixed ve = new VotingEscrowFixed(lock);
        lock.mint(address(this), ve.MAXTIME() * 2);
        lock.approve(address(ve), type(uint256).max);

        uint256 honest = ve.create_lock(ve.MAXTIME());
        uint256 mine = ve.create_lock(ve.MAXTIME());
        (, uint256 splitId) = ve.split(mine, ve.MAXTIME());

        uint256 rounded = ve.votingPower(honest);
        uint256 alsoRounded = ve.votingPower(splitId);
        assertEq(rounded, 62_899_199, "create_lock power");
        assertEq(alsoRounded, 62_899_199, "split power matches");
        assertFalse(alsoRounded > rounded, "split cannot outvote");

        (, uint256 endHonest) = ve.locked(honest);
        (, uint256 endSplit) = ve.locked(splitId);
        assertEq(endHonest, endSplit, "both ends week-aligned");
        assertEq(endSplit % ve.WEEK(), 0, "on a Thursday boundary");
    }
}
