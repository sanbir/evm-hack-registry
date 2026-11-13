// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, LpToken} from "./13255-convexpositionhandler-claimrewards-incorrectly-calculates-am.sol";

contract Finding13255Test is Test {
    function test_claim_unstakes_more_lp_than_the_eth_yield() public {
        Exploit e = new Exploit();
        e.run();

        LpToken lp = e.lp();
        assertEq(e.paid(), e.LP(), "paid");
        assertEq(e.fairPaid(), e.FAIR(), "fair");
        assertEq(lp.balanceOf(e.sink()), e.LP(), "sink");
        assertEq(lp.balanceOf(e.controlSink()), e.FAIR(), "control");
        assertEq(lp.balanceOf(address(e.buggy())), 0, "buggy left");
        assertEq(lp.balanceOf(address(e.fixedHandler())), e.FAIR(), "fixed left");

        console2.log("LP unstaked by buggy claim");
        console2.log(e.paid());
        console2.log("fair LP");
        console2.log(e.fairPaid());
        console2.log("buggy LP left");
        console2.log(e.buggyLeft());
        console2.log("fixed LP left");
        console2.log(e.fixedLeft());
    }
}
