// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Cash, MarketFixed} from "./45979-h-4-when-account-is-liquidated-protected-liquidator-can-incr.sol";

contract Finding45979Test is Test {
    function test_exploit_liquidation_sets_max_long_and_drains_makers() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), e.HUGE(), "attacker received 2**62-1");
        assertEq(e.cash().balanceOf(address(e.market())), 0, "maker cash gone");
        assertEq(e.cash().balanceOf(address(e)), e.HUGE(), "exploit holds the pile");
        assertEq(e.market().magnitudeOf(address(e)), 0, "settled");
    }

    function test_control_fixed_protection_rejects_a_larger_long() public {
        Cash cash = new Cash();
        MarketFixed fixedMarket = new MarketFixed(cash);
        uint256 huge = uint256(2 ** 62 - 1);
        cash.mint(address(fixedMarket), huge);
        fixedMarket.seed(address(this), 10, 10, 1e18, false);

        bool opened = fixedMarket.liquidate(address(this), huge);

        assertFalse(opened, "increase rejected");
        assertEq(fixedMarket.magnitudeOf(address(this)), 10, "position unchanged");
        assertEq(cash.balanceOf(address(fixedMarket)), huge, "maker cash stays");
    }
}
