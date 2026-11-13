// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, RewardToken, NFTRewardsFixed} from
    "./41818-h-8-liquidated-positions-will-still-accrue-rewards-after-bei.sol";

contract Finding41818Test is Test {
    function test_exploit_liquidated_nft_is_paid_5_rewards() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.claimed(), 5 ether, "claimed 5");
        assertEq(e.aliceCollateral(), 0, "collateral wiped");
        assertEq(e.aliceBalance(), 100 ether, "balance stale");
        assertEq(e.reward().balanceOf(address(e)), 5 ether, "alice holds 5");
    }

    function test_control_clearing_balance_pays_liquidated_user_zero() public {
        RewardToken reward = new RewardToken();
        NFTRewardsFixed distributor = new NFTRewardsFixed(reward);
        bytes32 asset = keccak256("TOKEN_A");
        distributor.supply(1, asset, 100 ether);
        distributor.supply(2, asset, 100 ether);
        distributor.liquidate(1, asset);
        distributor.notifyRewardAmount(asset, 10 ether);
        uint256 alice = distributor.getReward(1, asset, address(this));
        uint256 bob = distributor.getReward(2, asset, address(this));
        assertEq(alice, 0, "alice 0");
        assertEq(bob, 10 ether, "bob 10");
        assertEq(reward.balanceOf(address(this)), 10 ether, "only bob");
    }
}
