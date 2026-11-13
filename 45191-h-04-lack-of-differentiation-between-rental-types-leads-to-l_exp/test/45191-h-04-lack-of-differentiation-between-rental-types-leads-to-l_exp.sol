// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Estate, Coin} from "./45191-h-04-lack-of-differentiation-between-rental-types-leads-to-l.sol";

contract Finding45191Test is Test {
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant END = 1_700_000_000 + 86400;

    function test_long_cancel_refunds_usdc_for_a_junk_booking() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.usdcGain(), 1000, "attacker USDC");
        assertEq(e.usdcLeft(), 9000, "remaining user USDC");
        assertEq(e.fairUsdcLeft(), 10_000, "fair USDC untouched");
        console2.log("usdc gain", e.usdcGain());
        console2.log("usdc left", e.usdcLeft());
    }

    function test_control_refunds_the_booked_denom() public {
        Coin junk = new Coin();
        Coin usdc = new Coin();
        Estate estate = new Estate();
        junk.mint(address(this), 1000);
        usdc.mint(address(estate), 10_000);
        estate.seed(address(usdc), 10_000);
        junk.approve(address(estate), 1000);
        estate.setListForShortTerm(address(junk), 1000);
        estate.setListForLongTerm(address(usdc), 1000);
        estate.setReservationForShortTerm(START, END);

        (address denom, uint256 amount) = estate.cancelInBookedDenom(START, END);
        assertEq(denom, address(junk), "booked denom");
        assertEq(amount, 1000, "junk refund");
        assertEq(junk.balanceOf(address(this)), 1000, "junk returned");
        assertEq(usdc.balanceOf(address(estate)), 10_000, "USDC intact");
        console2.log("control refund", amount);
        console2.log("control usdc", usdc.balanceOf(address(estate)));
    }
}
