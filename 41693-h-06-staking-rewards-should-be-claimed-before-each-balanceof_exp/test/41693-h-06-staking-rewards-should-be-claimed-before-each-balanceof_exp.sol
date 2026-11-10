// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    RewardToken,
    DyadXP,
    RewardHolder,
    UniswapV3Staking
} from "./41693-h-06-staking-rewards-should-be-claimed-before-each-balanceof.sol";

contract Finding41693Test is Test {
    function test_exploit_withdraw_before_claim_pays_0_instead_of_1000() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 0, "claim paid 0");
        assertEq(e.fair(), 1000e18, "fair reward was 1000 KEROSENE");
        assertEq(e.userBalance(), 0, "user received 0");
        assertEq(e.holderBalance(), e.REWARD(), "1000 stuck in the reward holder");
        assertEq(e.fair() - e.paid(), 1000e18, "user lost 1000");
    }

    function test_control_claim_before_withdraw_pays_1000() public {
        RewardToken reward = new RewardToken();
        DyadXP xp = new DyadXP();
        RewardHolder holder = new RewardHolder();
        UniswapV3Staking staking = new UniswapV3Staking(xp, reward, address(holder), 1);
        xp.setNote(1, 1000e18);
        staking.stake(1, 1, 0);
        reward.mint(address(holder), 1000e18);
        holder.approve(reward, address(staking), 1000e18);

        // Claim while balanceOfNote is still 1000e18, then change the balance.
        uint256 paid = staking.claimRewards(1);
        xp.withdrawKerosene(1);

        assertEq(paid, 1000e18, "claim first pays 1000");
        assertEq(reward.balanceOf(address(this)), 1000e18, "user received 1000");
        assertEq(xp.balanceOfNote(1), 0, "xp dropped only after the claim");
        assertEq(reward.balanceOf(address(holder)), 0, "holder paid out");
    }
}
