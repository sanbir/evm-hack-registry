// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Asset, Exploit, LiquidityFacet, Lp} from "./57740-h-03-inaccurate-accounting-in-removeliquidity-overstating-li.sol";

contract Finding57740Test is Test {
    function test_pool_amount_overstates_and_the_later_lp_is_short_50() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.accounted(), 550 ether, "accounted 550");
        assertEq(e.tokensLeft(), 500 ether, "tokens 500");
        assertEq(e.gap(), 50 ether, "short 50");
        assertTrue(e.secondReverted(), "second withdraw reverts");
        assertEq(e.token().balanceOf(address(e.pool())), 500 ether, "pool still holds 500");
        assertEq(e.pool().lpOf(address(e.lp2())), 500 ether, "later LP still has the shares");
    }

    function test_control_subtracts_the_full_out_amount() public {
        Asset token = new Asset();
        Lp lp1 = new Lp();
        Lp lp2 = new Lp();
        LiquidityFacet pool = new LiquidityFacet(token, address(this), true);
        pool.seed(address(lp1), address(lp2), 500 ether);
        lp1.pull(pool, 500 ether);

        assertEq(pool.poolAmount(), 500 ether, "poolAmount matches the tokens");
        assertEq(token.balanceOf(address(pool)), 500 ether, "500 tokens left");
        assertEq(pool.shortfall(address(lp2)), 0, "extra is 0");
        lp2.pull(pool, 500 ether);
        assertEq(token.balanceOf(address(lp2)), 450 ether, "later LP receives the real net");
        assertEq(token.balanceOf(address(pool)), 0, "pool is empty");
        assertEq(pool.poolAmount(), 0, "accounting is zero");
    }
}
