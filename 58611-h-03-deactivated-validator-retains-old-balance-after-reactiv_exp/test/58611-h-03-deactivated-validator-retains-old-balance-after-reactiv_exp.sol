// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, ValidatorManager, MarkerToken} from "./58611-h-03-deactivated-validator-retains-old-balance-after-reactiv.sol";

// Kinetiq H-03 (finding 58611): ValidatorManager.deactivateValidator never zeroes
// validatorData.balance nor subtracts it from totalBalance. After the withdrawn
// stake leaves the system and the validator is reactivated, the routine oracle
// update `totalBalance = totalBalance - oldBalance + balance` subtracts the STALE
// balance from a smaller totalBalance -> underflow revert -> DoS.
contract Finding58611Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_staleBalanceUnderflowDoS() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("stale stored balance", e.staleBalance());
        emit log_named_uint("totalBalance at failure", e.totalBalanceAtFailure());

        // The stale balance exceeds totalBalance -> the subtraction underflows.
        assertGt(e.staleBalance(), e.totalBalanceAtFailure(), "stale balance must exceed totalBalance");

        // The routine oracle update reverted (DoS proven).
        assertTrue(e.updateReverted(), "updateValidatorPerformance must revert (underflow DoS)");

        // Bricked-accounting magnitude surfaced at the profit sink.
        MarkerToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), e.staleBalance(), "harm magnitude not recorded at sink");
        assertEq(marker.balanceOf(SINK), 100e18, "expected 100e18 bricked HYPE at sink");
    }
}
