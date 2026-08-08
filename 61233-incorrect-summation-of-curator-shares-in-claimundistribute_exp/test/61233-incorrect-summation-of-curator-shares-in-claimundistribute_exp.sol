// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    Rewards,
    RewardsFixed,
    MiniToken,
    VaultTokenized,
    L1Middleware,
    VaultManager,
    Math
} from "./61233-incorrect-summation-of-curator-shares-in-claimundistribute.sol";

contract IncorrectCuratorShareSummationTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant OPERATOR = 0x0000000000000000000000000000000000000a11;
    address internal constant CURATOR = 0x0000000000000000000000000000000000000C0C;
    address internal constant DISTRIBUTOR = 0x00000000000000000000000000000000000D1517;

    uint48 internal constant EPOCH = 1;
    uint256 internal constant TOTAL_REWARDS = 100_000 ether;

    function test_exploit_curatorSharesDoubleCounted_undercountsUndistributed() public {
        Exploit e = new Exploit();
        e.run();

        // The buggy path claims only 30% (30_000e18); the correct amount is 40% (40_000e18).
        assertEq(e.buggyClaimed(), 30_000 ether, "buggy under-claim");
        assertEq(e.correctClaimed(), 40_000 ether, "correct undistributed");
        assertLt(e.buggyClaimed(), e.correctClaimed(), "distributor received less than entitled");

        // The 10_000e18 deficit is stranded in the contract; recorded on the marker to SINK.
        assertEq(e.strandedDeficit(), 10_000 ether, "stranded deficit magnitude");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 10_000 ether, "marker records stranded amount at SINK");

        // Real tokens truly stranded: contract still holds more than the distributed 60%.
        MiniToken reward = MiniToken(Rewards(e.rewardsAddr()).rewardsToken());
        assertEq(reward.balanceOf(e.rewardsAddr()), 70_000 ether, "contract retains under-claimed pool");
    }

    function test_control_fixedSummation_claimsFullUndistributed() public {
        // Rebuild the identical scenario against the FIXED contract.
        MiniToken reward = new MiniToken("Reward", "RWD");
        VaultTokenized v1 = new VaultTokenized(CURATOR);
        VaultTokenized v2 = new VaultTokenized(CURATOR);
        L1Middleware mw = new L1Middleware();
        VaultManager vmgr = new VaultManager();
        RewardsFixed rewards = new RewardsFixed(address(mw), address(vmgr), address(reward));

        address[] memory operators = new address[](1);
        operators[0] = OPERATOR;
        mw.setOperators(operators);

        address[] memory vaults = new address[](2);
        vaults[0] = address(v1);
        vaults[1] = address(v2);
        vmgr.setVaults(EPOCH, vaults);

        uint256[] memory opShares = new uint256[](1);
        opShares[0] = 1000;
        uint256[] memory vShares = new uint256[](2);
        vShares[0] = 2000;
        vShares[1] = 2000;
        address[] memory curators = new address[](1);
        curators[0] = CURATOR;
        uint256[] memory cShares = new uint256[](1);
        cShares[0] = 1000;

        rewards.setEpochData(EPOCH, TOTAL_REWARDS, operators, opShares, vaults, vShares, curators, cShares);
        reward.mint(address(rewards), TOTAL_REWARDS);

        uint256 claimed = rewards.claimUndistributedRewards(EPOCH, DISTRIBUTOR);

        // Fixed path claims the full, correct 40% and strands nothing beyond the distributed 60%.
        assertEq(claimed, 40_000 ether, "fixed claims full undistributed");
        assertEq(reward.balanceOf(DISTRIBUTOR), 40_000 ether, "distributor received full entitlement");
        assertEq(reward.balanceOf(address(rewards)), 60_000 ether, "only the distributed 60% remains");
    }
}
