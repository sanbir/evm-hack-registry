// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./58131-h-04-traders-could-lose-assets-when-increasing-counter-trade.sol";
contract Finding58131Test is Test {
    function test_exploit_counter_trade_cancel_keeps_400() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.returnedWrong(), 600e18, "only 600 returned");
        assertEq(e.stuck(), 400e18, "400 lost");
        assertEq(e.returnedFair(), 1_000e18, "control returned 1000");
        assertEq(e.dai().balanceOf(address(e.book())), 400e18, "book holds the loss");
        assertEq(e.dai().balanceOf(address(e.fairBook())), 0, "control book empty");
    }
}
