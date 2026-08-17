// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, GNSTrading, MiniToken} from "./40188-h-01-inconsistent-spread-and-price-impact-charges-pashov-aud.sol";

// Gains Network H-01 (finding 40188): the position-size INCREASE path charges HALF
// spread+price-impact unconditionally (`getMarketExecutionPrice(..., true)`), while
// the CLOSE path returns market price and charges ZERO for a trade opened before
// v9.2 (`maxLiqSpreadP == 0`). A pre-v9.2 trader increases (pays 50%) then closes
// (pays 0%), avoiding the 50% the protocol should collect — 50e18 here.
contract Finding40188Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_preV92_avoids_full_spread_charge() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("pre-v9.2 increase charge (HALF)", e.increaseCharged());
        emit log_named_uint("pre-v9.2 close charge (ZERO)", e.closeCharged());
        emit log_named_uint("correct full increase baseline", e.fullChargeBaseline());
        emit log_named_uint("post-v9.2 close charge (contrast)", e.postV92CloseCharged());
        emit log_named_uint("uncollected spread (harm)", e.avoided());
        emit log_named_uint("shortfall minted to SINK", e.marker().balanceOf(SINK));

        // The increase charges only HALF the spread the pre-v9.2 trade owes...
        assertEq(e.increaseCharged(), 50e18, "increase charged half");
        // ...and the close charges NOTHING (pre-v9.2 early return).
        assertEq(e.closeCharged(), 0, "pre-v9.2 close charged zero");
        // A correct full charge on the increase would be 100e18.
        assertEq(e.fullChargeBaseline(), 100e18, "full increase baseline");
        // A post-v9.2 trade's close DOES collect the other half (total 100%).
        assertEq(e.postV92CloseCharged(), 50e18, "post-v9.2 close charges other half");

        // Quantified accounting harm: the 50e18 the protocol failed to collect on
        // the pre-v9.2 trade, recorded at the SINK marker.
        assertEq(e.avoided(), 50e18, "uncollected spread");
        assertEq(e.marker().balanceOf(SINK), 50e18, "shortfall recorded at sink");
    }
}
