// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    LogicFixed,
    Manager,
    Token
} from "./61560-missing-user-liquidity-sync-in-timeweightedincentivelogic-up.sol";

contract Finding61560Test is Test {
    function test_exploit_claim_pays_zero_of_fair_amount() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.userOnLogic(), 0, "logic never copied user liquidity");
        assertEq(e.paid(), 0, "claim pays 0");
        assertEq(e.paidAfterSync(), 0, "sync after the checkpoint pays 0");
        assertEq(e.stuck(), e.N(), "1000 RWD stays in the logic");
        assertEq(e.reward().balanceOf(address(e.logic())), 1000 ether);
    }

    function test_control_sync_pays_the_fair_amount() public {
        Token reward = new Token("Reward", "RWD", 18);
        Manager manager = new Manager();
        LogicFixed logic = new LogicFixed(reward, manager);
        manager.addLiquidity(address(this), 100 ether);
        reward.mint(address(this), 1000 ether);
        reward.approve(address(logic), 1000 ether);
        logic.depositRewards(1000 ether, 1000);
        logic.advance(1000);

        uint256 paid = logic.claim();
        assertEq(paid, 1000 ether, "control pays the fair amount");
        assertEq(reward.balanceOf(address(logic)), 0, "nothing stuck");
        assertEq(reward.balanceOf(address(this)), 1000 ether, "staker received N");
    }
}
