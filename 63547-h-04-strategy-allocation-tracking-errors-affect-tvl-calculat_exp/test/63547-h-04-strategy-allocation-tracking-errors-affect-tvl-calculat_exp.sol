// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, ElytraAssetVault, ElytraStrategy, USDC, MarkerToken} from
    "./63547-h-04-strategy-allocation-tracking-errors-affect-tvl-calculat.sol";

// Elytra H-04 (finding 63547): getTotalAssetTVL sums a static
// `assetsAllocatedToStrategies` counter that is never reconciled against the
// strategy's real balance, so in-strategy yield is silently dropped and reported
// TVL drifts below the assets the protocol truly controls. Allocate 100 -> yield
// +20 -> deallocate 60 => reported TVL 100 vs real holdings 120 (gap 20).
contract Finding63547Test is Test {
    function test_exploit_strategyTvlTrackingDrift() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("tracker after (stale)", e.trackerAfter());
        emit log_named_uint("strategy real balance", e.strategyRealAfter());
        emit log_named_uint("reported TVL", e.reportedTVL());
        emit log_named_uint("actual holdings", e.actualHoldings());
        emit log_named_uint("TVL gap (un-credited yield)", e.tvlGap());

        assertEq(e.trackerAfter(), 40e6, "tracker understated (should be 60)");
        assertEq(e.strategyRealAfter(), 60e6, "strategy really holds 60");
        assertEq(e.reportedTVL(), 100e6, "protocol reports TVL 100");
        assertEq(e.actualHoldings(), 120e6, "protocol truly holds 120");
        assertLt(e.reportedTVL(), e.actualHoldings(), "TVL drifted below real holdings");
        assertEq(e.tvlGap(), 20e6, "TVL under-reported by the full un-credited yield");
    }
}
