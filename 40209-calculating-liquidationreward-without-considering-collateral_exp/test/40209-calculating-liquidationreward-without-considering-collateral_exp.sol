// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit, LiquidationLibFixed} from "./40209-calculating-liquidationreward-without-considering-collateral.sol";
contract Finding40209Test is Test {
    function test_overpays_6_decimal_collateral() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paid(), 1e18, "buggy");
        assertEq(e.fair(), 1e6, "fair");
        assertGt(e.paid(), e.fair());
        assertEq(e.usdc().balanceOf(address(e)), 1e18);
        assertEq(e.usdc().balanceOf(address(e.vault())), 0);
    }
    function test_control_scales_by_collateral_decimals() public {
        uint256 fair = (new LiquidationLibFixed()).liquidationReward(1e18, 1e18, 1e18, 0, 6);
        assertEq(fair, 1e6);
    }
}
