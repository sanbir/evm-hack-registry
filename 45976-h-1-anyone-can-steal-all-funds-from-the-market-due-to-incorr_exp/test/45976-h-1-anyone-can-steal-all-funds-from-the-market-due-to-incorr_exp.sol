// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Cash, MarketFixed} from "./45976-h-1-anyone-can-steal-all-funds-from-the-market-due-to-incorr.sol";

contract Finding45976Test is Test {
    function test_exploit_three_intents_withdraw_20_of_lp_collateral() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.cash().balanceOf(address(e));
        e.run();

        assertEq(beforeBal, 40 ether, "attacker posted 40");
        assertEq(e.withdrawn(), 60 ether, "maker withdrew 60");
        assertEq(e.cash().balanceOf(address(e)), 60 ether, "net +20");
        assertEq(e.takerAfter(), -20 ether, "taker underwater");
        assertEq(e.cash().balanceOf(address(e.market())), 40 ether, "LP residual 40 of 60");
    }

    function test_control_third_intent_fails_the_summed_health_check() public {
        Cash cash = new Cash();
        MarketFixed market = new MarketFixed(cash);
        address taker = address(0x7A4E4);
        address lp = address(0x190);
        cash.mint(address(this), 100 ether);
        cash.approve(address(market), type(uint256).max);
        market.deposit(lp, 60 ether);
        market.deposit(taker, 40 ether);

        market.submit(taker, address(this), 1 ether, 120 ether);
        market.submit(taker, address(this), 1 ether, 120 ether);
        bool reverted;
        try market.submit(taker, address(this), 1 ether, 120 ether) {
            reverted = false;
        } catch {
            reverted = true;
        }

        assertTrue(reverted, "third intent reverted");
        assertEq(market.collateral(taker), 40 ether, "taker deposit intact");
        assertEq(cash.balanceOf(address(market)), 100 ether, "no withdrawal");
    }
}
