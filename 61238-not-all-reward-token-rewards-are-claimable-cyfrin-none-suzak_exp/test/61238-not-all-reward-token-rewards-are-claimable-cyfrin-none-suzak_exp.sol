// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Middleware,
    RewardsFixed,
    Token
} from "./61238-not-all-reward-token-rewards-are-claimable-cyfrin-none-suzak.sol";

contract Finding61238Test is Test {
    function test_exploit_token_b_stays_stuck() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.cursorAfterA(), 1, "claiming A advances the shared cursor");
        assertEq(e.paidA(), 100 ether, "token A is claimable");
        assertTrue(e.tokenBBlocked(), "token B claim is rejected");
        assertEq(e.stuckB(), 1_000 ether, "N of token B stays in the contract");
        assertEq(e.tokenA().balanceOf(address(this)), 100 ether, "caller received token A");
        assertEq(e.tokenB().balanceOf(address(this)), 0, "caller received no token B");
        assertEq(e.N(), 1_000 ether, "harm magnitude");
    }

    function test_control_claims_both_tokens() public {
        Token tokenA = new Token();
        Token tokenB = new Token();
        Middleware middleware = new Middleware();
        RewardsFixed rewards = new RewardsFixed(middleware);
        uint256 amountA = 100 ether;
        uint256 n = 1_000 ether;

        middleware.setEpoch(2);
        tokenA.mint(address(rewards), amountA);
        tokenB.mint(address(rewards), n);
        rewards.setReward(address(tokenA), 1, address(this), amountA);
        rewards.setReward(address(tokenB), 1, address(this), n);

        rewards.claimRewards(address(tokenA), address(this));
        assertEq(rewards.lastEpochClaimedStaker(address(this), address(tokenA)), 1, "A cursor is 1");
        assertEq(rewards.lastEpochClaimedStaker(address(this), address(tokenB)), 0, "B cursor is untouched");

        rewards.claimRewards(address(tokenB), address(this));
        assertEq(tokenA.balanceOf(address(this)), amountA, "control pays A");
        assertEq(tokenB.balanceOf(address(this)), n, "control pays N of B");
        assertEq(tokenB.balanceOf(address(rewards)), 0, "no token B left behind");
    }
}
