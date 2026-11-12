// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    RewardToken,
    StakingVault
} from "./55143-h-04-users-can-take-their-share-of-rewards-in-cycles-they-st.sol";

/// @dev Freeze the reward already in the closing cycle at unstake. Later deposits pay 0.
contract StakingVaultFixed is StakingVault {
    uint256 public frozenOwed;
    bool public froze;

    constructor(RewardToken token_) StakingVault(token_) {}

    function unstake() public override {
        uint256 shares = _rewardPoolShares[1][currentCycleId];
        uint256 reward = _rewardPoolRewards[1][currentCycleId];
        StakingVault.ClaimableReward memory r = _userRewardPoolClaimableReward[msg.sender][1];
        frozenOwed = reward * r.shares / shares;
        froze = true;
        super.unstake();
    }

    function claimRewardsToOwed() public override returns (uint256 paid) {
        require(froze, "not closed");
        paid = frozenOwed;
        frozenOwed = 0;
        if (paid != 0) rewardsToken.transfer(msg.sender, paid);
    }
}

contract Finding55143Test is Test {
    function test_exploit_takes_rewards_funded_after_unstake() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.rewardsToken().balanceOf(address(e)), 1000, "attacker took 1000");
        assertEq(e.vault()._rewardPoolRewards(1, 2), 0, "cycle 2 emptied");
    }

    function test_control_pays_zero_for_rewards_after_unstake() public {
        RewardToken token = new RewardToken();
        StakingVaultFixed vault = new StakingVaultFixed(token);
        vault.stake(100);
        vault.endCycleIfNeeded();
        vault.unstake();
        vault.acceptPositionManagerRewards(1000);
        vault.endCycleIfNeeded();
        uint256 paid = vault.claimRewardsToOwed();
        assertEq(paid, 0, "control pays 0");
        assertEq(token.balanceOf(address(this)), 0, "caller received nothing");
        assertEq(vault._rewardPoolRewards(1, 2), 1000, "the 1000 stays in the cycle");
    }
}
