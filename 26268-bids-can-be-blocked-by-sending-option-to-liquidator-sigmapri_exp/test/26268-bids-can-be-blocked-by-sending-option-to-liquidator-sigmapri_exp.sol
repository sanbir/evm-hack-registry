// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./26268-bids-can-be-blocked-by-sending-option-to-liquidator-sigmapri.sol";

contract FindingTest is Test {
    function test_block_bid() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.funded(), e.N(), "funded");
        assertEq(e.dustOnBidder(), e.DUST(), "dust");
        assertTrue(e.bidReverted(), "bid");
        assertEq(e.shortfallBeforeSettle(), e.N(), "shortfall");
        assertEq(e.socialized(), e.N(), "socialized");
        assertEq(e.insuranceGot(), 0, "insurance");
        assertEq(e.cash().balanceOf(address(e)), e.N(), "attacker");
        assertEq(e.controlInsurance(), e.N(), "control insurance");
        assertTrue(e.controlSettleReverted(), "control settle");
        assertEq(e.cashC().balanceOf(address(e)), 0, "control attacker");
        console2.log("dust");
        console2.log(e.dustOnBidder());
        console2.log("shortfall");
        console2.log(e.shortfallBeforeSettle());
        console2.log("socialized");
        console2.log(e.socialized());
        console2.log("insurance got");
        console2.log(e.insuranceGot());
        console2.log("control insurance");
        console2.log(e.controlInsurance());
    }
}
