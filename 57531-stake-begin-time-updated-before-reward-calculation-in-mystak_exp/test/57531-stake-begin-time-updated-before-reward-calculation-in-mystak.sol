// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * AuditVault 57531 — Magic Yearn MyStaking.stake (Zokyo, 2022-08).
 * setTimer() writes stakeBegin before getDivisorByTime() prices the fee.
 * A long-staker is charged the maximum commission (divisor 10) instead of
 * the long-stake commission (divisor 100).
 */

contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

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

contract MyStaking {
    MiniToken public immutable reward;
    address public immutable feeTo;
    mapping(address => uint256) public stakeBegin;
    mapping(address => uint256) public pendingReward;
    mapping(address => uint256) public unclaimedAmount;
    uint256 public lastFee;
    uint256 public lastNet;

    constructor(MiniToken _reward, address _feeTo) {
        reward = _reward;
        feeTo = _feeTo;
    }

    function seed(address user, uint256 rewardGross) external {
        stakeBegin[user] = 1;
        pendingReward[user] = rewardGross;
    }

    function getDivisorByTime(uint256 begin) public view returns (uint256) {
        uint256 elapsed = block.timestamp - begin;
        if (elapsed >= 365 days) return 100;
        return 10;
    }

    function setTimer(address user) public {
        stakeBegin[user] = block.timestamp;
    }

    function stake(uint256 addAmount) external {
        // @> VULN: stakeBegin is updated before getDivisorByTime prices the fee
        setTimer(msg.sender);
        uint256 gross = pendingReward[msg.sender];
        uint256 divisor = getDivisorByTime(stakeBegin[msg.sender]);
        uint256 fee = gross / divisor;
        uint256 net = gross - fee;
        pendingReward[msg.sender] = 0;
        unclaimedAmount[msg.sender] += gross;
        lastFee = fee;
        lastNet = net;
        if (addAmount > 0) {
            lastNet = net + addAmount;
        }
        reward.transfer(feeTo, fee);
        reward.transfer(msg.sender, net);
    }
}

contract MyStakingFixed {
    MiniToken public immutable reward;
    address public immutable feeTo;
    mapping(address => uint256) public stakeBegin;
    mapping(address => uint256) public pendingReward;
    mapping(address => uint256) public unclaimedAmount;
    uint256 public lastFee;
    uint256 public lastNet;

    constructor(MiniToken _reward, address _feeTo) {
        reward = _reward;
        feeTo = _feeTo;
    }

    function seed(address user, uint256 rewardGross) external {
        stakeBegin[user] = 1;
        pendingReward[user] = rewardGross;
    }

    function getDivisorByTime(uint256 begin) public view returns (uint256) {
        uint256 elapsed = block.timestamp - begin;
        if (elapsed >= 365 days) return 100;
        return 10;
    }

    function setTimer(address user) public {
        stakeBegin[user] = block.timestamp;
    }

    function stake(uint256) external {
        uint256 gross = pendingReward[msg.sender];
        uint256 divisor = getDivisorByTime(stakeBegin[msg.sender]);
        uint256 fee = gross / divisor;
        setTimer(msg.sender);
        uint256 net = gross - fee;
        pendingReward[msg.sender] = 0;
        unclaimedAmount[msg.sender] += gross;
        lastFee = fee;
        lastNet = net;
        reward.transfer(feeTo, fee);
        reward.transfer(msg.sender, net);
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant GROSS = 1000 ether;

    MiniToken public reward;
    MyStaking public staking;
    uint256 public feeTaken;
    uint256 public userNet;
    uint256 public extraOverFair;
    uint256 public divisorUsed;

    constructor() {
        reward = new MiniToken("MY Reward", "MYR");
        staking = new MyStaking(reward, SINK);
    }

    function run() external {
        reward.mint(address(staking), GROSS);
        staking.seed(address(this), GROSS);
        uint256 beginBefore = staking.stakeBegin(address(this));
        staking.stake(0);
        feeTaken = staking.lastFee();
        userNet = staking.lastNet();
        divisorUsed = staking.getDivisorByTime(staking.stakeBegin(address(this)));
        uint256 fairFee = GROSS / 100;
        extraOverFair = feeTaken - fairFee;
        require(beginBefore == 1, "seeded");
        require(divisorUsed == 10, "max divisor");
        require(feeTaken == 100 ether, "max fee");
        require(userNet == 900 ether, "net");
        require(extraOverFair == 90 ether, "extra");
        require(reward.balanceOf(SINK) == 100 ether, "fee sink");
        require(reward.balanceOf(address(this)) == 900 ether, "user");
    }
}
