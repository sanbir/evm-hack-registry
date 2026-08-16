// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, ReserveModule, MiniToken} from "./63401-h-01-parameter-change-skews-getters-pashov-audit-group-none.sol";

// RegnumAurum H-01 (finding 63401): getLiquidityIndex/getNormalizedIncome recompute
// the liquidity rate on the fly using the CURRENT protocolFeeRate instead of the
// cached currentLiquidityRate that updateState books. Raising the protocol fee
// 10% -> 30% after the last update skews getNormalizedIncome below the value the
// protocol actually accrues, understating a depositor's balance by 16 tokens.
contract Finding63401Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_parameterChangeSkewsGetter() public {
        // one year elapses since the reserve's last update (lastUpdateTimestamp = 0)
        vm.warp(365 days);

        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("getter income idx before fee change", e.incomeBeforeChange());
        emit log_named_uint("getter income idx after fee change ", e.incomeAfterChange());
        emit log_named_uint("index actually booked (cached rate)", e.bookedIndex());
        emit log_named_uint("depositor balance reported by getter", e.reportedBalance());
        emit log_named_uint("depositor balance actually booked   ", e.bookedBalance());
        emit log_named_uint("accounting error (tokens)           ", e.accountingError());

        // before the fee change the getter matched the booked value
        assertEq(e.incomeBeforeChange(), e.bookedIndex(), "getter consistent before change");
        // after the fee change the getter is skewed away from the booked value
        assertTrue(e.incomeAfterChange() != e.bookedIndex(), "getter skewed after change");
        assertLt(e.incomeAfterChange(), e.bookedIndex(), "fee up -> income under-reported");
        // concrete harm: depositor balance understated by exactly 16 tokens
        assertEq(e.accountingError(), 16 ether, "accounting error magnitude");
        assertEq(e.sinkMarkerBalance(), 16 ether, "harm recorded on SINK marker");
        assertEq(MiniToken(e.markerAddr()).balanceOf(SINK), 16 ether, "SINK holds the skew marker");
    }
}
