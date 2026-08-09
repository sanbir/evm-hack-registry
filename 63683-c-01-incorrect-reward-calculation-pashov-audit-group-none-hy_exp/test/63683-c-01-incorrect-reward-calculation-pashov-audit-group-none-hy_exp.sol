// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    NFTStaking,
    NFTStakingFixed,
    StakingRouter,
    MockRewardToken,
    MockERC721
} from "./63683-c-01-incorrect-reward-calculation-pashov-audit-group-none-hy.sol";

contract IncorrectRewardCalculationTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ALICE = 0x000000000000000000000000000000000000a11c;

    uint256 internal constant TOKEN_ID = 42;
    uint256 internal constant ACCRUED = 1000 ether;

    function test_exploit_routerUnstake_forfeitsUserRewards() public {
        Exploit e = new Exploit();
        e.run();

        // Alice unstaked via the router with 1000 HYBUX accrued, but _unstakeNFTs
        // claimed for msg.sender (the router), which has no position.
        assertEq(e.aliceRewardBalance(), 0, "Alice was paid nothing");
        assertEq(e.routerRewardBalance(), 0, "router (no position) received nothing either");

        // Her accrued reward and staked position are wiped -> permanently unrecoverable.
        assertEq(e.alicePendingAfter(), 0, "Alice's accrued reward wiped");
        assertEq(e.aliceStakedAfter(), 0, "Alice's position cleared");

        // NFT was returned, but the 1000 HYBUX reward is forfeited.
        MockERC721 nft = MockERC721(address(NFTStaking(e.stakingAddr()).nft()));
        assertEq(nft.ownerOf(TOKEN_ID), ALICE, "NFT returned to Alice");

        // Forfeited magnitude recorded on the marker at the SINK.
        assertEq(e.lostAmount(), ACCRUED, "1000 HYBUX forfeited");
        MockRewardToken marker = MockRewardToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), ACCRUED, "marker records forfeited amount at SINK");

        // The reward pool sits idle in the staking contract: it was never disbursed.
        MockRewardToken reward = MockRewardToken(e.rewardAddr());
        assertEq(reward.balanceOf(e.stakingAddr()), ACCRUED, "reward pool never paid out");
    }

    function test_control_fixedClaimsForSender_userReceivesRewards() public {
        // Rebuild the identical scenario against the FIXED staking contract.
        MockRewardToken reward = new MockRewardToken("HYBUX Reward", "HYBUX");
        MockERC721 nft = new MockERC721();
        NFTStakingFixed staking = new NFTStakingFixed(address(reward), address(nft));
        StakingRouterFixed router = new StakingRouterFixed(address(staking));
        staking.setStakingRouter(address(router));

        nft.mint(address(staking), TOKEN_ID);
        uint256[] memory ids = new uint256[](1);
        ids[0] = TOKEN_ID;
        staking.seedPosition(ALICE, ids, ACCRUED);
        reward.mint(address(staking), ACCRUED);

        router.unstakeNFTs(ALICE, ids);

        // Fixed path claims for the delegated user: Alice receives her full 1000.
        assertEq(reward.balanceOf(ALICE), ACCRUED, "Alice receives her full reward");
        assertEq(reward.balanceOf(address(staking)), 0, "reward pool fully disbursed");
        assertEq(staking.rewards(ALICE), 0, "no residual accrual");
        assertEq(nft.ownerOf(TOKEN_ID), ALICE, "NFT returned to Alice");
    }
}

/// @dev Router double bound to the FIXED staking contract for the negative control.
contract StakingRouterFixed {
    address public staking;

    constructor(address _staking) {
        staking = _staking;
    }

    function unstakeNFTs(address _sender, uint256[] calldata _tokenIds) external {
        NFTStakingFixed(staking).unstakeNFTsRouter(_sender, _tokenIds);
    }
}
