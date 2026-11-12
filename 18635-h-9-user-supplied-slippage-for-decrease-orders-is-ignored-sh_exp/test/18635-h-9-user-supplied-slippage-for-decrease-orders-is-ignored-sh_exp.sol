// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./18635-h-9-user-supplied-slippage-for-decrease-orders-is-ignored-sh.sol";

contract Finding18635Test is Test {
    function test_decrease_fill_is_worse_than_user_minimum_both_amounts() public {
        Exploit e = new Exploit();
        e.run();

        console2.log("user min", e.userMin());
        console2.log("fair profit quote", e.fairProfitOut());
        console2.log("profit-swap received", e.profitReceived());
        console2.log("fair collateral quote", e.fairCollateralOut());
        console2.log("collateral-swap received", e.collateralReceived());
        console2.log("searcher pnl profit", e.pnlProfit());
        console2.log("searcher col profit", e.colProfit());

        assertEq(e.userMin(), 900 ether, "min");
        assertEq(e.fairProfitOut(), 990 ether, "fair profit");
        assertEq(e.fairCollateralOut(), 990 ether, "fair collateral");
        assertLt(e.profitReceived(), e.userMin(), "profit fill under min");
        assertLt(e.collateralReceived(), e.userMin(), "collateral fill under min");
        assertEq(e.profitReceived(), 248743718592964824120, "profit amount");
        assertEq(e.collateralReceived(), 248743718592964824120, "collateral amount");
        assertEq(e.col().balanceOf(e.TRADER()), e.profitReceived(), "trader collateral");
        assertEq(e.pnl().balanceOf(e.TRADER()), e.collateralReceived(), "trader pnl");
        assertEq(e.pnlProfit(), 750629722921914357682, "pnl profit");
        assertEq(e.colProfit(), 750629722921914357682, "col profit");
    }

    function test_control_reverts_when_min_is_enforced() public {
        Exploit e = new Exploit();
        vm.expectRevert(bytes("InsufficientOutputAmount"));
        e.runControl();
    }
}
