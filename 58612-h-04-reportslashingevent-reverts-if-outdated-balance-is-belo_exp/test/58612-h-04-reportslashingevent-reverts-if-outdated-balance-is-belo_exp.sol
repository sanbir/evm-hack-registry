// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, ValidatorManager, OracleManager, MarkerToken} from "./58612-h-04-reportslashingevent-reverts-if-outdated-balance-is-belo.sol";

// Kinetiq H-04 (finding 58612): ValidatorManager.reportSlashingEvent guards with
// `require(val.balance >= amount, "Insufficient stake for slashing")`, comparing a
// newly-reported slash against the STALE, last-reported stored balance. When a
// validator's real balance has grown past its last-reported value, the averaged
// slash can exceed the stored balance and the require reverts. Because
// OracleManager.generatePerformance calls reportSlashingEvent inside its
// per-validator loop, the whole hourly oracle update reverts -> DoS.
contract Finding58612Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_slashingRevertBricksGeneratePerformance() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("stale stored balance (valA)", e.vuln().balanceOfValidator(address(0xA11CE)));
        emit log_named_uint("unrecordable slash", e.unrecordableSlash());
        emit log_named_string("revert reason", e.revertReason());

        // The whole generatePerformance oracle update reverted (DoS proven)...
        assertTrue(e.performanceReverted(), "generatePerformance must revert (DoS)");

        // ...and it reverted on exactly the flagged require.
        assertEq(e.revertReason(), "Insufficient stake for slashing", "revert must be the flagged slashing require");

        // The averaged slash (110e18) exceeds the stale stored balance (100e18),
        // even though it is far below the validator's real balance (500e18).
        assertGt(e.unrecordableSlash(), e.vuln().balanceOfValidator(address(0xA11CE)), "slash must exceed stale stored balance");

        // Bricked-update magnitude surfaced at the profit sink.
        MarkerToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), e.unrecordableSlash(), "harm magnitude not recorded at sink");
        assertEq(marker.balanceOf(SINK), 110e18, "expected 110e18 unrecordable slash at sink");
    }
}
