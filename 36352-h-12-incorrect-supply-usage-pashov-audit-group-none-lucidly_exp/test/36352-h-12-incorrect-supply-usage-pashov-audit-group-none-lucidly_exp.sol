// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    LpToken,
    PoolFixed
} from "./36352-h-12-incorrect-supply-usage-pashov-audit-group-none-lucidly.sol";

contract Finding36352Test is Test {
    function test_exploit_remove_pays_short_and_product_is_high() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid0(), 20 ether, "holder received 20 token0");
        assertEq(e.FAIR_PAID() - e.paid0(), 5 ether, "short 5 of the fair 25");
        assertEq(e.product(), 1562500000000000000, "product is 1.5625e18");
        assertEq(e.product() - e.FAIR_PRODUCT(), e.PRODUCT_GAP(), "product high by 0.5625e18");
        assertEq(e.pool().supply(), 200 ether, "invariant supply was not the input");
        assertEq(e.lp().totalSupply(), 200 ether, "LP supply fell by the burn only");
        assertEq(e.token0().balanceOf(address(e.holder())), 20 ether, "token0 balance");
        assertEq(e.token1().balanceOf(address(e.holder())), 20 ether, "token1 balance");
    }

    function test_control_supply_pays_the_fair_amount() public {
        Asset token0 = new Asset();
        Asset token1 = new Asset();
        LpToken lp = new LpToken();
        PoolFixed pool = new PoolFixed(token0, token1, lp);
        pool.seed(address(this));
        pool.removeLiquidity(50 ether, address(this));

        assertEq(token0.balanceOf(address(this)), 25 ether, "fair token0 is 25");
        assertEq(token1.balanceOf(address(this)), 25 ether, "fair token1 is 25");
        assertEq(pool.storedProd(), 1 ether, "product uses the updated supply");
        assertEq(pool.supply(), 150 ether, "supply fell by the burned LP");
        assertEq(pool.paid0(), 25 ether, "recorded fair payout");
    }
}
