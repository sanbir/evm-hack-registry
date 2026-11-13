// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    Cash
} from "./11480-h01-malicious-market-can-arbitrarily-decide-when-to-pay-affi.sol";

contract Finding11480Test is Test {
    function test_malicious_validator_skips_affiliate_payment_and_honest_pays() public {
        Exploit e = new Exploit();
        e.run();

        Cash cash = e.cash();
        assertEq(e.skippedSource(), 0, "skipped source");
        assertEq(e.skippedReferrer(), 0, "skipped referrer");
        assertEq(e.skimmed(), e.N(), "skim");
        assertEq(cash.balanceOf(address(e.creator())), e.N(), "creator");
        assertEq(e.controlPaid(), e.N(), "control paid");
        assertEq(e.controlSource(), e.N() / 5, "source 20%");
        assertEq(e.controlReferrer(), e.N() - (e.N() / 5), "referrer");
        assertEq(e.attackMarket().affiliateFeesAttoCash(address(e.referrer())), 0, "attack accrual");
        assertEq(e.controlMarket().affiliateFeesAttoCash(address(e.referrer())), e.N() - (e.N() / 5), "control accrual");
        assertEq(e.attackMarket().marketCreatorFeesAttoCash(), e.FEE() - e.N(), "attack fair fees");
        assertEq(e.controlMarket().marketCreatorFeesAttoCash(), e.FEE() - e.N(), "control fair fees");

        console2.log("affiliate N skipped");
        console2.log(e.N());
        console2.log("creator skimmed");
        console2.log(e.skimmed());
        console2.log("attack source paid");
        console2.log(e.skippedSource());
        console2.log("attack referrer paid");
        console2.log(e.skippedReferrer());
        console2.log("control paid");
        console2.log(e.controlPaid());
        console2.log("control source cut");
        console2.log(e.controlSource());
        console2.log("control referrer");
        console2.log(e.controlReferrer());
    }
}
