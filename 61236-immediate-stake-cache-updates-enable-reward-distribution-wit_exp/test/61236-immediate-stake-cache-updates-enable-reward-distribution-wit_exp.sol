// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    IStakeMiddleware,
    MiddlewareFixed,
    Rewards,
    Token
} from "./61236-immediate-stake-cache-updates-enable-reward-distribution-wit.sol";

contract Finding61236Test is Test {
    function test_exploit_pays_extra_reward_on_unconfirmed_stake() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.cachedStake(), 50 ether, "cache holds the unconfirmed stake");
        assertTrue(e.stillPending(), "P-Chain has not confirmed");
        assertEq(e.inflatedPaid(), 5 ether, "reward used the unconfirmed stake");
        assertEq(e.extraPaid(), 4 ether, "extra over the confirmed-stake reward");
        assertEq(e.reward().balanceOf(address(this)), 4 ether, "attacker kept the extra 4 RWD");
        assertEq(e.EXTRA(), 4 ether, "harm magnitude");
    }

    function test_control_waits_for_confirmation() public {
        Token reward = new Token();
        MiddlewareFixed middleware = new MiddlewareFixed();
        Rewards rewards = new Rewards(IStakeMiddleware(address(middleware)), reward);
        reward.mint(address(rewards), 5 ether);

        middleware.seedConfirmedStake(10 ether);
        middleware.initializeValidatorStakeUpdate(50 ether);
        assertEq(middleware.nodeStakeCache(2, middleware.validationID()), 10 ether, "cache stays confirmed");
        assertTrue(middleware.nodePendingUpdate(middleware.validationID()), "update still pending");

        middleware.setEpoch(2);
        uint256 paid = rewards.distributeOperatorReward(address(this), address(this));
        assertEq(paid, 1 ether, "control pays the confirmed stake only");
        assertEq(reward.balanceOf(address(this)), 1 ether, "no extra reward before confirmation");

        middleware.completeStakeUpdate();
        assertEq(middleware.nodeStakeCache(2, middleware.validationID()), 10 ether, "epoch 2 was not rewritten");
        assertEq(middleware.nodeStakeCache(3, middleware.validationID()), 50 ether, "new stake lands only after confirm");
        assertFalse(middleware.nodePendingUpdate(middleware.validationID()), "pending cleared on confirm");
    }
}
