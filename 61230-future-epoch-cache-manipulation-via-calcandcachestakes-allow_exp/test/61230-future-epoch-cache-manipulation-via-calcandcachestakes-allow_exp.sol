// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MiddlewareFixed,
    Token
} from "./61230-future-epoch-cache-manipulation-via-calcandcachestakes-allow.sol";

contract Finding61230Test is Test {
    address constant HONEST = address(0xB0B);

    function test_cached_future_epoch_pays_600_instead_of_200() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.cachedStake(), 100 ether, "cached stake stayed 100");
        assertEq(e.fairShare(), 200 ether, "fair share is 200");
        assertEq(e.paid(), 600 ether, "attacker is paid 600");
        assertGt(e.paid(), e.fairShare(), "paid more than fair");
        assertEq(e.reward().balanceOf(address(e)), 600 ether, "attacker balance");
        assertEq(e.reward().balanceOf(HONEST), 600 ether, "honest operator was shorted");
    }

    function test_control_ignores_the_future_cache() public {
        Token reward = new Token();
        MiddlewareFixed middleware = new MiddlewareFixed(reward);
        address attacker = address(this);

        middleware.setOperators(attacker, HONEST);
        middleware.setStake(attacker, 100 ether);
        middleware.setStake(HONEST, 100 ether);
        uint256 cached = middleware.calcAndCacheStakes(5, 1);
        assertEq(cached, 0, "future epoch is ignored");
        assertFalse(middleware.totalStakeCached(5, 1), "flag stays clear");

        middleware.setStake(attacker, 20 ether);
        reward.mint(address(middleware), 1200 ether);
        uint256 paid = middleware.claim(attacker, 5, 1, 1200 ether);

        assertEq(paid, 200 ether, "control pays the fair 200");
        assertEq(reward.balanceOf(attacker), 200 ether, "attacker balance");
        assertEq(middleware.getOperatorStake(attacker, 5, 1), 20 ether, "live stake");
    }
}
