// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./46495-incorrect-casting-in-bridge-getroyaltypercentage-leads-to-mi.sol";

contract Finding46495Test is Test {
    function test_probe_amount_is_paid_as_a_percentage() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.creatorGot(), 1e15, "creator");
        assertEq(e.fairCreator(), 1e16, "fair creator");
        assertEq(e.kept(), 9e15, "seller keeps the shortfall");
        assertEq(e.sellerGot(), 1 ether - 1e15, "seller proceeds");
        console2.log("creator got", e.creatorGot());
        console2.log("fair creator", e.fairCreator());
        console2.log("kept", e.kept());
    }

    function test_control_one_percent_of_one_ether_is_1e16() public {
        Exploit e = new Exploit();
        uint256 fair = e.bridge().fairRoyalty(1 ether);
        assertEq(fair, 1e16, "1% of 1 ether");
        console2.log("control royalty", fair);
    }
}
