// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Middleware,
    RewardsFixed,
    Token
} from "./61234-incorrect-reward-claim-logic-causes-loss-of-access-to-interm.sol";

contract Finding61234Test is Test {
    function test_exploit_epoch2_rewards_become_unclaimable() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.cursorAfterFirstClaim(), 4, "cursor set to currentEpoch - 1");
        assertTrue(e.secondClaimBlocked(), "later claim cannot see epoch 2");
        assertEq(e.stranded(), 1_000 ether, "N stays in the rewards contract");
        assertEq(e.reward().balanceOf(address(this)), 100 ether, "only epoch 1 was paid");
        assertEq(e.N(), 1_000 ether, "harm magnitude");
    }

    function test_control_pays_the_intermediate_epoch() public {
        Token reward = new Token();
        Middleware middleware = new Middleware();
        RewardsFixed rewards = new RewardsFixed(middleware);
        uint256 epoch1 = 100 ether;
        uint256 n = 1_000 ether;
        reward.mint(address(rewards), epoch1 + n);

        middleware.setEpoch(5);
        rewards.distributeRewards(1, address(this), epoch1, rewards.BPS());
        rewards.claimOperatorFee(address(reward), address(this));
        assertEq(rewards.lastEpochClaimedOperator(address(this), address(reward)), 1, "cursor stops at the paid epoch");

        rewards.distributeRewards(2, address(this), n, rewards.BPS());
        middleware.setEpoch(9);
        rewards.claimOperatorFee(address(reward), address(this));

        assertEq(reward.balanceOf(address(this)), epoch1 + n, "control pays N");
        assertEq(reward.balanceOf(address(rewards)), 0, "nothing stranded");
    }
}
