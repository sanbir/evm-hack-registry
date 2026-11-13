// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DIA DIARewardsDistribution.updateRewardRatePerDay
    (MixBytes, Lumina Staking, 2025-06, finding 7).
    SYNTHETIC, cheatcode-free. The accrual line is verbatim.

    100 days already sit between rewardLastUpdateTime and this block.
    The rate in force was 1,000. The owner sets 2,000. The function accrues
    (newRate * days) / 10000 = 20 instead of oldRate * days = 100,000.
    A 10,000 principal is then paid 20 WDIA instead of 100,000.
    The gap is stored in the constructor. run() does not warp. */

contract StakeToken {
    string public constant name = "WDIA";
    string public constant symbol = "WDIA";
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

contract DIARewardsDistribution {
    uint256 public constant SECONDS_IN_A_DAY = 1 days;
    StakeToken public STAKING_TOKEN;
    uint256 public rewardRatePerDay;
    uint256 public rewardAccumulator;
    uint256 public rewardLastUpdateTime;
    address public owner;

    struct StakingStore {
        uint256 principal;
        uint256 rewardAccumulator;
    }

    StakingStore public store;

    constructor(StakeToken token_, uint256 oldRate) {
        STAKING_TOKEN = token_;
        owner = msg.sender;
        rewardRatePerDay = oldRate;
        rewardLastUpdateTime = block.timestamp - 100 days;
        store.principal = 10_000 ether;
    }

    function updateRewardRatePerDay(uint256 newRewardRate) external {
        require(msg.sender == owner, "owner");
        rewardRatePerDay = newRewardRate;
        uint256 daysElapsed = (block.timestamp - rewardLastUpdateTime) / SECONDS_IN_A_DAY;
        // @> VULN: rewardsAccrued = (rewardRatePerDay * daysElapsed) / 10000 uses the new rate and divides twice
        uint256 rewardsAccrued = (rewardRatePerDay * daysElapsed) / 10000;
        rewardAccumulator += rewardsAccrued;
        rewardLastUpdateTime = block.timestamp;
    }

    function claim() external returns (uint256 stakerReward) {
        uint256 stakerDelta = rewardAccumulator - store.rewardAccumulator;
        store.rewardAccumulator = rewardAccumulator;
        stakerReward = (stakerDelta * store.principal) / 10000;
        if (stakerReward > 0) STAKING_TOKEN.transfer(msg.sender, stakerReward);
    }
}

contract DIARewardsDistributionFixed {
    uint256 public constant SECONDS_IN_A_DAY = 1 days;
    StakeToken public STAKING_TOKEN;
    uint256 public rewardRatePerDay;
    uint256 public rewardAccumulator;
    uint256 public rewardLastUpdateTime;
    address public owner;
    uint256 public principal = 10_000 ether;
    uint256 public userIndex;

    constructor(StakeToken token_, uint256 oldRate) {
        STAKING_TOKEN = token_;
        owner = msg.sender;
        rewardRatePerDay = oldRate;
        rewardLastUpdateTime = block.timestamp - 100 days;
    }

    function updateRewardRatePerDay(uint256 newRewardRate) external {
        require(msg.sender == owner, "owner");
        uint256 oldRewardRate = rewardRatePerDay;
        uint256 daysElapsed = (block.timestamp - rewardLastUpdateTime) / SECONDS_IN_A_DAY;
        uint256 rewardsAccrued = oldRewardRate * daysElapsed;
        rewardAccumulator += rewardsAccrued;
        rewardRatePerDay = newRewardRate;
        rewardLastUpdateTime = block.timestamp;
    }

    function claim() external returns (uint256 stakerReward) {
        uint256 stakerDelta = rewardAccumulator - userIndex;
        userIndex = rewardAccumulator;
        stakerReward = (stakerDelta * principal) / 10000;
        if (stakerReward > 0) STAKING_TOKEN.transfer(msg.sender, stakerReward);
    }
}

contract Exploit {
    uint256 public constant OLD_RATE = 1_000;
    uint256 public constant NEW_RATE = 2_000;
    uint256 public constant FAIR = 100_000 ether;
    uint256 public constant PAID = 20 ether;

    StakeToken public token; // nonce 1
    DIARewardsDistribution public dist; // nonce 2

    uint256 public accrued;
    uint256 public received;
    uint256 public kept;

    constructor() {
        token = new StakeToken();
        dist = new DIARewardsDistribution(token, OLD_RATE);
        token.mint(address(dist), FAIR);
    }

    function run() external {
        dist.updateRewardRatePerDay(NEW_RATE);
        accrued = dist.rewardAccumulator();
        received = dist.claim();
        kept = token.balanceOf(address(dist));
        require(accrued == 20, "accumulator is 20");
        require(received == PAID, "paid 20");
        require(kept == FAIR - PAID, "99980 stays");
    }
}
