// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Token,
    VotingEscrowFixed
} from "./58158-h-07-inconsistent-rounding-of-lock-time-causes-voting-power.sol";

contract Finding58158Test is Test {
    function test_exploit_unrounded_split_inflates_power_and_slope() public {
        assertEq(block.timestamp, 1, "timestamp");
        Exploit e = new Exploit();
        e.run();
        assertEq(e.fairPower(), 62_899_199 ether, "rounded power");
        assertEq(e.inflatedPower(), 63_072_000 ether, "split power");
        assertEq(e.inflatedPower() - e.fairPower(), 172_801 ether, "excess");
        assertEq(e.residualSlope(), int128(uint128(1 ether)), "slope remains");
        assertEq(e.reward().balanceOf(address(this)), 63_072_000 ether, "claimed the inflated power");
        assertEq(e.claimed(), 63_072_000 ether, "governor paid that power");
    }

    function test_control_rounded_split_matches_create_lock_and_clears_slope() public {
        assertEq(block.timestamp, 1, "timestamp");
        Token lock = new Token("Kitten Lock", "LOCK");
        VotingEscrowFixed ve = new VotingEscrowFixed(lock);
        lock.mint(address(this), 63_072_000 ether);
        lock.approve(address(ve), type(uint256).max);
        uint256 id = ve.create_lock(63_072_000 ether);
        uint256 fair = ve.votingPower(id);
        (, uint256 id2) = ve.split(id, 63_072_000 ether);
        assertEq(ve.votingPower(id2), fair, "split power equals the week-aligned lock");
        assertEq(fair, 62_899_199 ether, "fair power");
        int128 slope = ve.slopeAt(105 * 7 days);
        assertEq(slope, 0, "slope removed on the week boundary");
        assertEq(ve.residualSlope(), 0, "stored residual");
    }
}
