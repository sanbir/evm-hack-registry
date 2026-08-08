// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    StakedINTX,
    StakedINTXFixed,
    MiniToken
} from "./59427-user-pending-rewards-can-never-be-paid-out-quantstamp-inte.sol";

contract PendingRewardsLostTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_pending_rewards_wiped_without_payout() public {
        Exploit e = new Exploit();
        e.run();

        uint256 pendingBefore = e.pendingBefore();
        uint256 pendingAfter = e.pendingAfter();
        uint256 received = e.received();
        uint256 lost = e.lost();

        // Staker had a non-zero accrued balance.
        assertEq(pendingBefore, 1_000 ether, "precondition: staker had pending rewards");
        // After claim, the pending balance is wiped to zero...
        assertEq(pendingAfter, 0, "pending rewards zeroed by claim");
        // ...but the staker received NOTHING.
        assertEq(received, 0, "staker receives zero reward tokens");
        // The wiped amount is a permanent self-loss, recorded on the SINK marker.
        assertEq(lost, 1_000 ether, "full pending balance lost");

        MiniToken lossMarker = e.lossMarker();
        assertEq(lossMarker.balanceOf(SINK), 1_000 ether, "loss marker equals wiped rewards");

        // The reward tokens are still stranded in the staking contract, unrecoverable
        // by this staker via claim().
        MiniToken rewardToken = e.rewardToken();
        assertEq(rewardToken.balanceOf(address(e.staking())), 1_000 ether, "rewards stranded in staking contract");
    }

    function test_control_fixed_pays_out_pending() public {
        // Same inputs, but exercise the fixed variant directly.
        MiniToken rewardToken = new MiniToken("INTX");
        StakedINTXFixed staking = new StakedINTXFixed(rewardToken);

        uint256 pending = 1_000 ether;
        uint256 tokenId = 7;

        rewardToken.mint(address(staking), pending);
        staking.setPendingRewards(address(this), pending);
        staking.setTokenRewards(tokenId, 0);

        uint256 before = rewardToken.balanceOf(address(this));
        staking.claim(tokenId); // msg.sender == this == token owner

        uint256 got = rewardToken.balanceOf(address(this)) - before;

        // Fixed: staker actually receives their full pending balance.
        assertEq(got, pending, "fixed variant pays out the full pending balance");
        assertEq(staking.pendingRewards(address(this)), 0, "pending zeroed after successful payout");
        assertEq(rewardToken.balanceOf(address(staking)), 0, "no rewards stranded");
    }
}
