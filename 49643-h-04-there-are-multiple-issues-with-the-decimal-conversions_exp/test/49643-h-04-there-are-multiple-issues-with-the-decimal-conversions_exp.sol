// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Usdc, StrategyLeverageFixed} from
    "./49643-h-04-there-are-multiple-issues-with-the-decimal-conversions.sol";

contract Finding49643Test is Test {
    function test_exploit_redeems_1e12_times_the_fair_usdc() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.got(), 1 ether, "raw 1e18");
        assertEq(e.fair(), 1e6, "fair 1 USDC");
        assertEq(e.usdc().balanceOf(address(e)), 1 ether, "attacker");
        assertEq(e.usdc().balanceOf(address(e.strategy())), 999 ether, "pool left short");
    }

    function test_control_scales_18_to_6_and_pays_1_usdc() public {
        Usdc usdc = new Usdc();
        StrategyLeverageFixed strategy = new StrategyLeverageFixed(usdc);
        strategy.seed(address(this), 1000 ether, 1000 ether);
        usdc.mint(address(strategy), 1000 ether);
        uint256 got = strategy.redeem(1 ether);

        assertEq(got, 1e6, "1 USDC");
        assertEq(usdc.balanceOf(address(this)), 1e6, "caller");
        assertEq(usdc.balanceOf(address(strategy)), 1000 ether - 1e6, "rest stays");
    }
}
