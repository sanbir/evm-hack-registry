// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    IncentiveLogicFixed,
    LIQUIDITY,
    LP,
    RewardToken
} from "./61553-reward-tokens-can-become-inaccessible-due-to-revert-when-rew.sol";

contract Finding61553Test is Test {
    function test_exploit_uint96_downcast_locks_rewards() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.claimReverted(), "claim should revert");
        assertEq(e.stuck(), 10 ether, "10 ether stuck");
        assertEq(e.token().balanceOf(LP), 0, "LP received nothing");
        assertGt(e.rawPerToken(), type(uint96).max, "raw reward-per-token exceeds uint96");
    }

    function test_control_uint256_pays_the_rewards() public {
        RewardToken token = new RewardToken();
        IncentiveLogicFixed logic = new IncentiveLogicFixed(token);
        token.mint(address(this), 10 ether);
        logic.notifyLiquidity(LIQUIDITY);
        token.approve(address(logic), 10 ether);
        logic.depositRewards(10 ether, 1);
        uint256 paid = logic.claim(LP);
        assertEq(paid, 10 ether, "wider type pays 10 ether");
        assertEq(token.balanceOf(LP), 10 ether, "LP received the rewards");
        assertEq(token.balanceOf(address(logic)), 0, "logic was emptied");
    }
}
