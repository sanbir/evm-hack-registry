// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    StakingERC20,
    StakingERC20Fixed
} from "./59358-loss-of-pending-reward-when-unstaking-quantstamp-zero-stak.sol";

contract Finding59358Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_loss_of_pending_reward_on_exit_unstake() public {
        Exploit e = new Exploit();
        e.run();

        // Rewards that were owed to the honest staker at unstake time.
        uint256 lost = e.lostRewards();
        assertEq(lost, 100e18, "expected 100e18 accrued rewards");

        // The bug: user received ZERO rewards despite owedRewards > 0.
        assertEq(e.rewardsReceived(), 0, "user should have received rewards but got none");

        // Principal was returned (only the pending rewards are lost).
        assertEq(e.stakedReturned(), 1_000e18, "staked principal must be returned");

        // Marker records the exact magnitude of the self-loss at SINK.
        MiniToken marker;
        // Recover marker via deterministic accounting: the marker minted `lost` to SINK.
        // Assert the harm marker balance directly.
        // (marker address is internal; assert through the minted supply at SINK below.)
        marker; // silence unused

        // The only token that minted to SINK is the marker; its SINK balance == lost rewards.
        // We assert on the public snapshot instead of the internal marker handle.
        assertEq(lost, 100e18, "lost rewards magnitude");
    }

    function test_exploit_marker_balance_at_sink() public {
        // Independent check that the marker token holds the loss magnitude at SINK.
        // Re-run and inspect the marker token created as the 4th `new` in run().
        Exploit e = new Exploit();
        e.run();

        // Deterministic address of the marker: Exploit is the deployer of the 4
        // helper contracts. Nonce 4 corresponds to the marker MiniToken.
        address markerAddr = computeCreateAddress(address(e), 4);
        MiniToken marker = MiniToken(markerAddr);

        assertEq(marker.balanceOf(SINK), 100e18, "marker at SINK must equal lost rewards");
        assertEq(e.lostRewards(), marker.balanceOf(SINK), "marker equals measured loss");
    }

    function test_control_fixed_pays_rewards_on_exit_unstake() public {
        // Same attack inputs against the fixed implementation -> no loss.
        MiniToken stakingToken = new MiniToken("STAKE");
        MiniToken rewardsToken = new MiniToken("REWARD");
        StakingERC20Fixed staking = new StakingERC20Fixed(stakingToken, rewardsToken);

        uint256 stakeAmount = 1_000e18;
        stakingToken.mint(address(this), stakeAmount);
        stakingToken.approve(address(staking), stakeAmount);
        rewardsToken.mint(address(staking), 1_000_000e18);

        staking.stake(stakeAmount);
        staking.warp(100);

        uint256 owed = staking.pendingRewards(address(this));
        assertEq(owed, 100e18, "expected 100e18 accrued rewards");

        staking.unstake(stakeAmount, true);

        // Fixed: user receives the full owed rewards even on exit unstake.
        assertEq(rewardsToken.balanceOf(address(this)), 100e18, "fixed must pay owed rewards");
        assertEq(stakingToken.balanceOf(address(this)), 1_000e18, "principal returned");
    }
}
