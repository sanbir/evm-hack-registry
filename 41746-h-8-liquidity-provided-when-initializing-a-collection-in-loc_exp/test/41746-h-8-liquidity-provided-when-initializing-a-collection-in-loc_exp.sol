// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Erc20, PoolManagerFixed, ImplementationFixed} from
    "./41746-h-8-liquidity-provided-when-initializing-a-collection-in-loc.sol";

contract Finding41746Test is Test {
    function test_exploit_initializer_liquidity_stays_in_the_pool() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.weth().balanceOf(address(e.pool())), 10 ether, "10 WETH locked");
        assertEq(e.col().balanceOf(address(e.pool())), 10 ether, "collection side locked");
        assertEq(e.pool().liquidityOf(address(e.impl())), 10 ether, "implementation owns it");
        assertEq(e.weth().balanceOf(address(e)), 0, "user recovered nothing");
        assertEq(e.col().balanceOf(address(e)), 0, "user collection is gone");
    }

    function test_control_same_caller_can_remove_the_liquidity() public {
        Erc20 weth = new Erc20("WETH");
        Erc20 col = new Erc20("COLL");
        PoolManagerFixed pool = new PoolManagerFixed(weth, col);
        ImplementationFixed impl = new ImplementationFixed(pool, weth, col);
        weth.mint(address(this), 10 ether);
        col.mint(address(this), 10 ether);
        weth.approve(address(impl), 10 ether);
        col.approve(address(impl), 10 ether);
        impl.initializeCollection(10 ether, 10 ether);
        assertEq(weth.balanceOf(address(pool)), 10 ether, "deposited");

        impl.removeLiquidity();
        assertEq(weth.balanceOf(address(pool)), 0, "pool empty");
        assertEq(col.balanceOf(address(pool)), 0, "col empty");
        assertEq(weth.balanceOf(address(this)), 10 ether, "user recovered WETH");
        assertEq(col.balanceOf(address(this)), 10 ether, "user recovered collection");
    }
}
