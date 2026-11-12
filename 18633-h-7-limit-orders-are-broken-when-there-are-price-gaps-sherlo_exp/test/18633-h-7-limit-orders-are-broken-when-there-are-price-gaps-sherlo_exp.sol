// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    LimitBook
} from "./18633-h-7-limit-orders-are-broken-when-there-are-price-gaps-sherlo.sol";

contract Finding18633Test is Test {
    function test_gap_reverts_stop_and_trader_is_stuck() public {
        Exploit e = new Exploit();
        e.run();

        LimitBook book = e.book();
        console2.log("caught selector matches", e.caught() == bytes4(keccak256("InvalidOrderPrices(uint256,uint256,uint256,bool)")));
        console2.log("revert primary", e.revertPrimary());
        console2.log("revert secondary", e.revertSecondary());
        console2.log("revert trigger", e.revertTrigger());
        console2.log("filled", e.filledFlag());
        console2.log("open size", e.openSize());
        console2.log("fair equity", e.fairEquity());
        console2.log("gap equity", e.gapEquity());
        console2.log("stuck collateral", e.stuck());
        console2.log("trader balance", e.traderBal());

        assertEq(e.caught(), bytes4(keccak256("InvalidOrderPrices(uint256,uint256,uint256,bool)")), "selector");
        assertEq(e.revertPrimary(), 1700 ether, "primary");
        assertEq(e.revertSecondary(), 1600 ether, "secondary");
        assertEq(e.revertTrigger(), 1900 ether, "trigger");
        assertEq(e.revertAscending(), false, "descending arm");
        assertEq(e.filledFlag(), false, "not filled");
        assertEq(book.filled(), false, "book not filled");
        assertEq(book.paid(), 0, "paid 0");
        assertEq(book.executionPrice(), 0, "no execution price");
        assertEq(e.openSize(), 10000 ether, "long still open");
        assertEq(book.sizeUsd(), 10000 ether, "size");
        assertEq(book.collateral(), 2000 ether, "collateral still posted");
        assertEq(e.fairEquity(), 1500 ether, "stop would have left 1500");
        assertEq(e.gapEquity(), 0, "gapped equity is 0");
        assertEq(e.stuck(), 2000 ether, "2000 stuck in the book");
        assertEq(e.token().balanceOf(address(book)), 2000 ether, "book balance");
        assertEq(e.traderBal(), 0, "trader paid nothing");
        assertEq(e.token().balanceOf(address(e.trader())), 0, "trader balance");
        assertEq(uint256(book.equityAt(1600 ether)), 0, "mark");
        assertEq(uint256(book.equityAt(1900 ether)), 1500 ether, "fair mark");
    }

    function test_control_gap_fills_at_trigger_and_pays_fair() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("control filled", e.controlFilled());
        console2.log("control price", e.controlPrice());
        console2.log("control paid", e.controlPaid());
        console2.log("control trader", e.controlTraderBal());
        console2.log("control book", e.controlBookBal());
        console2.log("control size", e.controlSize());

        assertEq(e.controlFilled(), true, "filled");
        assertEq(e.controlPrice(), 1900 ether, "trigger price, not 1600");
        assertEq(e.controlPaid(), 1500 ether, "fair payout");
        assertEq(e.controlTraderBal(), 1500 ether, "trader received 1500");
        assertEq(e.controlBookBal(), 500 ether, "book keeps the 500 stop loss");
        assertEq(e.controlSize(), 0, "position closed");
        assertEq(e.token().balanceOf(address(e.trader())), 1500 ether, "token");
    }

    function test_straddle_still_fills_at_trigger() public {
        Exploit e = new Exploit();
        e.runStraddle();

        LimitBook book = e.book();
        console2.log("straddle price", book.executionPrice());
        console2.log("straddle paid", book.paid());

        assertEq(book.filled(), true, "straddle fills");
        assertEq(book.executionPrice(), 1900 ether, "still the trigger");
        assertEq(book.paid(), 1500 ether, "same fair payout");
        assertEq(book.sizeUsd(), 0, "closed");
        assertEq(e.token().balanceOf(address(e.trader())), 1500 ether, "trader");
        assertEq(e.token().balanceOf(address(book)), 500 ether, "book retains 500");
    }
}
