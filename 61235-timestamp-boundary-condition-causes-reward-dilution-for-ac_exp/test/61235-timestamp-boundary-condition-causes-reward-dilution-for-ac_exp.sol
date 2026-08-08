// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    Rewards,
    AvalancheL1MiddlewareFixed
} from "./61235-timestamp-boundary-condition-causes-reward-dilution-for-ac.sol";

contract Finding61235Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant CHARLIE = address(uint160(0xC4A711E));

    uint96 internal constant ASSET_CLASS = 1;
    uint48 internal constant EPOCH = 7;
    uint48 internal constant EPOCH_START_TS = 1000;
    uint256 internal constant STAKE = 100 ether;
    uint256 internal constant TOTAL_REWARDS = 100 ether;

    function test_exploit_boundaryRewardDilution() public {
        Exploit e = new Exploit();
        e.run();

        // The buggy `>=` counts Alice (disabled exactly at epoch start) as active,
        // so totalStake is inflated to 2x the truly-active stake.
        assertEq(e.totalStakeBuggy(), 2 * STAKE, "buggy total stake should include disabled operator");

        // Charlie deserves 100% of rewards but only receives half.
        assertEq(e.charlieRewardCorrect(), TOTAL_REWARDS, "correct reward is full");
        assertEq(e.charlieRewardBuggy(), TOTAL_REWARDS / 2, "buggy reward is diluted to half");

        // The lost (diluted) reward is recorded at SINK via the marker token.
        uint256 lost = e.lostReward();
        assertEq(lost, TOTAL_REWARDS / 2, "lost reward equals half the rewards");

        // MiniToken marker is the LAST helper created in run() (nonce 3 from Exploit).
        MiniToken marker = MiniToken(_computeAddr(address(e), 3));
        assertEq(marker.balanceOf(SINK), lost, "marker records diluted reward at SINK");
        assertGt(marker.balanceOf(SINK), 0, "harm magnitude is non-zero");
    }

    function test_control_fixedNoDilution() public {
        // Exercise the Fixed middleware with the SAME inputs.
        AvalancheL1MiddlewareFixed middleware = new AvalancheL1MiddlewareFixed();
        Rewards rewards = new Rewards();

        middleware.setEpochStartTs(EPOCH_START_TS);
        middleware.registerOperator(address(0xA11c), 100, EPOCH_START_TS, STAKE); // disabled at boundary
        middleware.registerOperator(CHARLIE, 100, 0, STAKE); // active

        uint256 totalStake = middleware.calcAndCacheStakes(EPOCH, ASSET_CLASS);

        // Fixed `>` correctly excludes the boundary-disabled operator.
        assertEq(totalStake, STAKE, "fixed total stake excludes disabled operator");

        uint256 charlieStake = middleware.operatorStakeCache(EPOCH, ASSET_CLASS, CHARLIE);
        uint256 charlieReward = rewards.operatorReward(charlieStake, totalStake, TOTAL_REWARDS);

        // Charlie receives his full, undiluted share.
        assertEq(charlieReward, TOTAL_REWARDS, "fixed reward is undiluted (full)");
    }

    function _computeAddr(address deployer, uint256 nonce) internal pure returns (address) {
        // RLP encoding of (deployer, nonce) for small nonces (1..127).
        bytes memory data = abi.encodePacked(
            bytes1(0xd6), bytes1(0x94), deployer, bytes1(uint8(nonce))
        );
        return address(uint160(uint256(keccak256(data))));
    }
}
