// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Usd, MarketFixed} from "./49978-incorrect-autodeleveragefactor-codehawks-zaros-part-2-git.sol";

contract Finding49978Test is Test {
    address internal constant TRADER = 0x0000000000000000000000000000000000000B0b;

    function test_exploit_adl_start_pays_trader_zero() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 0, "paid 0");
        assertEq(e.kept(), 100 ether, "kept 100");
        assertEq(e.usd().balanceOf(TRADER), 0, "trader");
        assertEq(e.usd().balanceOf(address(e.market())), 100 ether, "market");
        assertEq(e.market().lastFactor(), 0, "factor");
    }

    function test_control_one_minus_x_pays_full_pnl() public {
        Usd usd = new Usd();
        MarketFixed market = new MarketFixed(usd);
        usd.mint(address(this), 100 ether);
        usd.approve(address(market), 100 ether);

        uint256 paid = market.settle(TRADER);

        assertEq(market.lastFactor(), 1e18, "factor 1");
        assertEq(paid, 100 ether, "full pnl");
        assertEq(usd.balanceOf(TRADER), 100 ether, "trader");
        assertEq(usd.balanceOf(address(market)), 0, "market empty");
        assertEq(market.kept(), 0, "nothing kept");
    }
}
