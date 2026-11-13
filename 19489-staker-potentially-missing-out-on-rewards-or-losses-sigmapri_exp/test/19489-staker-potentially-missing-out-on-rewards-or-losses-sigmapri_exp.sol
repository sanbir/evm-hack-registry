// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    StakingPoolFixed
} from "./19489-staker-potentially-missing-out-on-rewards-or-losses-sigmapri.sol";

contract Finding19489Test is Test {
    function test_withdraw_pays_100e18_instead_of_110e18() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.fair(), 110 ether, "fair share of the reward is 110e18");
        assertEq(e.paid(), 100 ether, "withdraw paid the bare stake");
        assertEq(e.fair() - e.paid(), 10 ether, "staker missed 10e18");
        assertEq(e.pool().pendingReward(), 100 ether, "reward was never folded in");
    }

    function test_control_updates_rewards_and_pays_110e18() public {
        Asset asset = new Asset();
        StakingPoolFixed pool = new StakingPoolFixed(asset);
        asset.mint(address(this), 1100 ether);
        pool.stake(address(0xBEEF), 900 ether);
        pool.stake(address(this), 100 ether);
        pool.earn(100 ether);
        assertEq(pool.fairAssets(address(this)), 110 ether, "fair is 110e18");

        uint256 beforeBal = asset.balanceOf(address(this));
        pool.withdraw(address(this));
        assertEq(asset.balanceOf(address(this)) - beforeBal, 110 ether, "control pays the fair 110e18");
        assertEq(pool.pendingReward(), 0, "reward was folded in");
    }
}
