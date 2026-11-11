// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    EquilibriumPoolFixed,
    Exploit,
    QuoteToken,
    Trader
} from "./48376-improper-unit-conversion-in-ammequilibrium-ottersec-none-ver.sol";

contract Finding48376Test is Test {
    function test_exploit_quote_off_by_1e36() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 1, "paid 1");
        assertEq(e.fair(), 1e36, "fair quote is 1e36");
        assertEq(e.fair() / e.paid(), 1e36, "factor");
        assertEq(e.retained(), 1e36 - 1, "shortfall stays in the pool");
        assertEq(e.token().balanceOf(address(e.trader())), 1, "trader");
        assertEq(e.pool().baseOut(), int256(1e36), "base leg");
        assertEq(e.pool().quoteOut(), 1, "quote leg");
    }

    function test_control_converts_with_fromInt() public {
        QuoteToken token = new QuoteToken();
        Trader trader = new Trader();
        EquilibriumPoolFixed pool = new EquilibriumPoolFixed(token, address(trader));
        token.mint(address(pool), 1e36);
        pool.swap();

        assertEq(pool.quoteOut(), int256(1e36), "fromInt quote");
        assertEq(pool.paid(), 1e36, "pays 1e36");
        assertEq(token.balanceOf(address(trader)), 1e36, "trader paid in full");
        assertEq(token.balanceOf(address(pool)), 0, "pool emptied");
    }
}
