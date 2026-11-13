// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Cash} from "./11481-h02-market-creators-can-avoid-paying-20-cut-of-affiliate-fee.sol";

contract Finding11481Test is Test {
    function test_creator_fingerprint_front_run_skips_source_cut() public {
        Exploit e = new Exploit();
        e.run();

        Cash cash = e.cash();
        assertEq(e.controlCut(), e.N(), "control cut");
        assertEq(cash.balanceOf(address(e.trader())), e.N(), "trader");
        assertEq(e.referrerAccrued(), 800 ether, "accrued");
        assertEq(e.skippedCut(), 0, "skipped");
        assertEq(e.creatorKept(), e.N(), "kept");
        assertEq(cash.balanceOf(address(e.creator())), e.N(), "creator balance");
        assertEq(e.attackMarket().affiliateFeesAttoCash(address(e.creator())), 0, "no attack accrual");

        console2.log("source cut N");
        console2.log(e.N());
        console2.log("control paid the cut");
        console2.log(e.controlCut());
        console2.log("referrer accrued on control");
        console2.log(e.referrerAccrued());
        console2.log("attack source cut");
        console2.log(e.skippedCut());
        console2.log("creator kept the cut");
        console2.log(e.creatorKept());
    }
}
