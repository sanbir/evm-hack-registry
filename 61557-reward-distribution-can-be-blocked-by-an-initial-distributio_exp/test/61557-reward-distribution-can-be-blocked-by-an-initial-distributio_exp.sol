// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    LogicFixed,
    Token
} from "./61557-reward-distribution-can-be-blocked-by-an-initial-distributio.sol";

contract Finding61557Test is Test {
    function test_exploit_second_notify_pays_zero() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.secondReverted(), "second notify reverts");
        assertEq(e.paid(), 0, "staker receives 0");
        assertEq(e.held(), e.N(), "100 RWD never enters the pool");
        assertEq(e.firstEnd(), type(uint32).max - 1, "first distribution fills uint32");
        assertEq(e.reward().balanceOf(address(e.funder())), 100 ether);
    }

    function test_control_capped_duration_pays_the_second_distribution() public {
        Token reward = new Token("Reward", "RWD", 18);
        LogicFixed logic = new LogicFixed(reward);
        logic.stake(1 ether);
        reward.mint(address(this), 604800 + 100 ether);
        reward.approve(address(logic), type(uint256).max);

        logic.depositRewards(604800, 1 weeks);
        logic.advance(3 days);
        logic.depositRewards(100 ether, 1 weeks);
        logic.advance(950400);

        uint256 paid = logic.claim();
        assertEq(paid, 99_999999999999792000, "control pays the second distribution");
        assertGt(paid, 99 ether, "staker received the streamed rewards");
    }
}
