// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    ShortBook,
    Zeth
} from "./27450-users-can-avoid-liquidation-while-being-under-the-primary-li.sol";

contract Finding27450Test is Test {
    // LibOrders.STARTING_TIME + 20 hours. Same value as setup.blockTimestamp.
    // The warp is outside run(); run() itself never changes the clock.
    uint256 internal constant FORK_TS = 1_660_353_637 + 20 hours;

    function test_last_short_keeps_1200_zeth() public {
        vm.warp(FORK_TS);
        Exploit e = new Exploit();
        e.run();

        ShortBook book = e.book();
        Zeth zeth = e.zeth();

        assertEq(e.stayedCollateral(), 1_200 ether, "stayed collateral");
        assertEq(book.collateralOf(254), 1_200 ether, "last short still holds 1200 zETH");
        assertLt(book.cRatioOf(254), book.PRIMARY_LIQUIDATION_CR(), "still under primary CR");
        assertGt(book.cRatioOf(254), book.MINIMUM_CR(), "above minimum CR");
        assertEq(book.updatedAtOf(254), book.hoursNow(), "merge refreshed updatedAt");
        assertTrue(e.lastLiquidationBlocked(), "liquidation reverted");

        assertEq(e.controlSeized(), 1_200 ether, "control seized");
        assertEq(book.collateralOf(2), 0, "control short closed");
        assertEq(zeth.balanceOf(address(e.liq())), 1_200 ether, "liquidator received control collateral");
        assertEq(zeth.balanceOf(address(book)), 1_200 ether, "market still custodies the last short");
        console2.log("stayed zETH wei", e.stayedCollateral());
        console2.log("control seized zETH wei", e.controlSeized());
        console2.log("last cRatio", book.cRatioOf(254));
        console2.log("updatedAt", book.updatedAtOf(254));
    }

    function test_control_liquidates_the_same_window_without_merge() public {
        vm.warp(FORK_TS);
        Exploit e = new Exploit();
        e.runControl();

        assertEq(e.book().collateralOf(254), 0, "unmerged last short is liquidated");
        assertEq(e.zeth().balanceOf(address(e.liq())), 1_200 ether, "control seized 1200 zETH");
        assertEq(e.zeth().balanceOf(address(e.book())), 0, "market released the collateral");
        console2.log("control liquidated last short, seized zETH wei", e.zeth().balanceOf(address(e.liq())));
    }
}
