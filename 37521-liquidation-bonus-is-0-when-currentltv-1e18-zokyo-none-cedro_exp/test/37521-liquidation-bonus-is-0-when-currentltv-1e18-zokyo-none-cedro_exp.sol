// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Collateral,
    LiquidationManagerFixed
} from "./37521-liquidation-bonus-is-0-when-currentltv-1e18-zokyo-none-cedro.sol";

contract Finding37521Test is Test {
    function test_exploit_bonus_is_zero_above_one_wad() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.discount(), 0, "discount is 0");
        assertEq(e.seized(), 1000 ether, "seized 1000");
        assertEq(e.FAIR_SEIZED() - e.seized(), 100 ether, "unpaid bonus is 100");
        assertEq(e.collateral().balanceOf(address(e)), 1000 ether, "liquidator balance");
    }

    function test_control_max_discount_seizes_1100() public {
        Collateral collateral = new Collateral();
        LiquidationManagerFixed manager = new LiquidationManagerFixed(collateral, 0.1 ether);
        collateral.mint(address(manager), 2000 ether);

        uint256 seized = manager.liquidate(1.2 ether, 1000 ether, address(this));

        assertEq(manager.lastDiscount(), 0.1 ether, "max discount applied");
        assertEq(seized, 1100 ether, "control seizes 1100");
        assertEq(collateral.balanceOf(address(this)), 1100 ether, "liquidator received the bonus");
    }
}
