// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    OracleBookFixed,
    SettleToken,
    Trader
} from "./47982-incorrect-oracle-garbage-collection-ottersec-none-switchboar.sol";

contract Finding47982Test is Test {
    function test_exploit_read_is_zero_and_payout_short() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.priceRead(), 0, "later read is 0");
        assertEq(e.book().paid(), 0, "payout is 0");
        assertEq(e.book().readPrice(), 0, "settle stored 0");
        assertEq(e.retained(), 2000 ether, "pot keeps the fair payout");
        assertEq(e.token().balanceOf(address(e.book())), 2000 ether, "book balance");
        assertEq(e.token().balanceOf(address(e.trader())), 0, "trader balance");
        assertEq(e.book().numRows(e.LIVE()), 0, "live numRows zeroed");
        assertEq(e.book().numRows(e.DEAD()), 1, "dead numRows kept");
        assertEq(e.FAIR() - e.book().paid(), 2000 ether, "wrong by 2000e18");
    }

    function test_control_keeps_live_oracle_and_pays_fair() public {
        SettleToken token = new SettleToken();
        Trader trader = new Trader();
        OracleBookFixed book = new OracleBookFixed(token, address(trader));
        token.mint(address(book), 2000 ether);
        book.enroll(address(0xDEAD), int256(500 ether), 0);
        book.enroll(address(0xBEEF), int256(2000 ether), block.timestamp);
        book.oracleHeartbeat(address(0xBEEF));

        assertEq(book.numRows(address(0xBEEF)), 1, "live row kept");
        assertEq(book.numRows(address(0xDEAD)), 0, "dead row cleared");
        assertEq(book.latestPrice(), 2000 ether, "fair price");

        book.settle();
        assertEq(book.paid(), 2000 ether, "fair payout");
        assertEq(token.balanceOf(address(trader)), 2000 ether, "trader paid");
        assertEq(token.balanceOf(address(book)), 0, "pot emptied");
    }
}
