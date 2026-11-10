// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    RewardToken,
    AuraRewardPool,
    IAuraRewardPool
} from "./35120-h-7-users-can-deny-the-vault-from-claiming-reward-tokens-she.sol";

/// Recommended fix: credit the vault's entire reward-token balance, not the
/// before/after delta. A permissionless getReward front-run then still pays.
contract VaultRewarderFixed {
    RewardToken public reward;
    AuraRewardPool public pool;
    uint256 public accountedReward;

    constructor(RewardToken _reward, AuraRewardPool _pool) {
        reward = _reward;
        pool = _pool;
    }

    function claimVaultRewards() external {
        uint256 balanceAfter = reward.balanceOf(address(this));
        require(IAuraRewardPool(address(pool)).getReward(address(this), true));
        balanceAfter = reward.balanceOf(address(this));
        // FIX: use the entire balance, not balanceAfter - balancesBefore.
        accountedReward = balanceAfter;
    }

    function payDepositors(address to) external {
        uint256 owed = accountedReward;
        accountedReward = 0;
        if (owed != 0) reward.transfer(to, owed);
    }
}

contract Finding35120Test is Test {
    address internal constant DEPOSITOR = 0x000000000000000000000000000000000000bEEF;

    function test_exploit_front_run_sticks_1000_rewards_in_the_vault() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.accountedAfter(), 0, "secondary reward accounting stayed 0");
        assertEq(e.vaultBalanceAfter(), e.REWARD(), "1000 AURA stuck in the vault");
        assertEq(e.depositorPaid(), 0, "depositor was paid 0");
        assertEq(e.reward().balanceOf(DEPOSITOR), 0, "depositor balance is 0");
        assertEq(e.REWARD(), 1000e18, "harm magnitude");
    }

    function test_control_entire_balance_pays_the_depositor_after_front_run() public {
        RewardToken reward = new RewardToken();
        AuraRewardPool pool = new AuraRewardPool(reward);
        VaultRewarderFixed vault = new VaultRewarderFixed(reward, pool);
        reward.mint(address(pool), 1000e18);
        pool.setEarned(address(vault), 1000e18);

        // Same front-run. The tokens are already in the vault before claim.
        pool.getReward(address(vault), true);
        assertEq(reward.balanceOf(address(vault)), 1000e18, "front-run delivered 1000");

        vault.claimVaultRewards();
        assertEq(vault.accountedReward(), 1000e18, "entire balance is credited");

        vault.payDepositors(DEPOSITOR);
        assertEq(reward.balanceOf(DEPOSITOR), 1000e18, "depositor received 1000");
        assertEq(reward.balanceOf(address(vault)), 0, "vault retained nothing");
    }
}
