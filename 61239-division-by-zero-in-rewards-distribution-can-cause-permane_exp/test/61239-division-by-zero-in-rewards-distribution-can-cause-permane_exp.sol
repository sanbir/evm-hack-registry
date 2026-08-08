// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    RewardsFixed,
    MockAvalancheL1Middleware,
    MiniToken
} from "./61239-division-by-zero-in-rewards-distribution-can-cause-permane.sol";

contract Rewards61239Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant BLOCKED_EPOCH_REWARDS = 1000 ether;

    function test_exploit_divisionByZero_locksEpochRewards() public {
        Exploit e = new Exploit();
        e.run();

        // The historical-epoch distribution reverted (division by zero on the new asset class).
        assertTrue(e.distributionReverted(), "distribution should revert with div-by-zero");

        // Harm marker: the blocked epoch rewards are permanently locked -> minted to SINK.
        assertEq(e.lockedRewards(), BLOCKED_EPOCH_REWARDS, "locked reward magnitude");
        MiniToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), BLOCKED_EPOCH_REWARDS, "SINK holds locked epoch rewards marker");
    }

    function test_control_fixedSkipsZeroStakeAssetClass() public {
        // Reproduce the SAME preconditions the Exploit sets up, against the Fixed contract.
        MockAvalancheL1Middleware mw = new MockAvalancheL1Middleware();
        RewardsFixed rewards = new RewardsFixed(mw);

        uint48 epoch = 1;
        address operator = ATTACKER;

        mw.setTotalStakeCache(epoch, 1, 200 ether);
        mw.setTotalStakeCache(epoch, 2, 200 ether);
        mw.setTotalStakeCache(epoch, 3, 200 ether);
        mw.setOperatorStake(epoch, operator, 1, 100 ether);
        mw.setOperatorStake(epoch, operator, 2, 100 ether);
        mw.setOperatorStake(epoch, operator, 3, 100 ether);
        rewards.setRewardsShareForAssetClass(1, 3000);
        rewards.setRewardsShareForAssetClass(2, 3000);
        rewards.setRewardsShareForAssetClass(3, 3000);

        uint96[] memory classes = new uint96[](4);
        classes[0] = 1;
        classes[1] = 2;
        classes[2] = 3;
        classes[3] = 4; // new asset class with zero historical stake
        mw.setAssetClassIds(classes);
        rewards.setRewardsShareForAssetClass(4, 1000);

        // Distribution succeeds: the zero-stake asset class is skipped instead of reverting.
        rewards.distributeRewards(epoch, operator);

        // Each of classes 1..3: mulDiv(100e18*10000/200e18=5000, 3000, 10000)=1500 -> 4500 total.
        assertEq(rewards.totalShare(), 4500, "fixed distribution computes shares without reverting");
    }
}
