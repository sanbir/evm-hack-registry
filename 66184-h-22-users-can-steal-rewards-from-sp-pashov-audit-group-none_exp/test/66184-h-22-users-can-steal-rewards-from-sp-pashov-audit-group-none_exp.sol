// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, StablePoolFixed} from "./66184-h-22-users-can-steal-rewards-from-sp-pashov-audit-group-none.sol";

contract Finding66184Test is Test {
    function test_exploit_two_withdraws_take_200_raac() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.raacTaken(), 200 ether, "stole 50 above the 150 entitlement");
        assertEq(e.raacLeft(), 100 ether, "victim short 50");
        assertEq(e.raacToken().balanceOf(address(e)), 200 ether, "attacker holds 200");
    }

    function test_control_recorded_reward_pays_150() public {
        Token r = new Token("R");
        Token de = new Token("DE");
        Token raac = new Token("RAAC");
        StablePoolFixed pool = new StablePoolFixed(de, r, raac);
        pool.seed(address(this), 150 ether);
        pool.seed(address(0xBEEF), 150 ether);
        pool.notifyReward(1 ether);
        r.mint(address(pool), 300 ether);
        raac.mint(address(pool), 300 ether);

        pool.withdraw(75 ether);
        pool.withdraw(75 ether);

        assertEq(raac.balanceOf(address(this)), 150 ether, "control pays the fair 150");
        assertEq(raac.balanceOf(address(pool)), 150 ether, "victim share remains");
    }
}
