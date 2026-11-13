// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, TradingFixed} from "./37794-h-05-closetrademarket-providing-wrong-value-when-triggering.sol";

contract Finding37794Test is Test {
    function test_exploit_zero_link_fee_locks_usdc_collateral() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paid(), 0, "paid");
        assertEq(e.fair(), 1e11, "fair");
        assertTrue(e.settleReverted(), "settle");
        assertEq(e.locked(), 1000e6, "locked");
        assertEq(e.usdc().balanceOf(address(e)), 0, "user");
        assertEq(e.link().balanceOf(e.oracle()), 0, "oracle");
    }

    function test_control_collateral_precision_pays_link_and_returns_usdc() public {
        Token usdc = new Token("USDC", 6);
        Token link = new Token("LINK", 18);
        address oracle = address(0x3333333333333333333333333333333333333333);
        TradingFixed trading = new TradingFixed(usdc, link, oracle);
        link.mint(address(trading), 1e11);
        usdc.mint(address(this), 1000e6);
        usdc.approve(address(trading), 1000e6);
        trading.openTrade();
        trading.closeTradeMarket();
        assertEq(trading.linkPaid(), 1e11, "fee");
        trading.settle();
        assertEq(usdc.balanceOf(address(this)), 1000e6, "usdc");
        assertEq(link.balanceOf(oracle), 1e11, "oracle");
        assertEq(usdc.balanceOf(address(trading)), 0, "empty");
    }
}
