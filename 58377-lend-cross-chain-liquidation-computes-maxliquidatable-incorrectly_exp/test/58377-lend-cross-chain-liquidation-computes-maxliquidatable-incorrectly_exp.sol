// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, LendStorage, CrossChainRouter, MarkerToken} from "./58377-lend-cross-chain-liquidation-computes-maxliquidatable-incorrectly.sol";

// LEND (Sherlock 2025-05) H-8, finding 58377: getMaxLiquidationRepayAmount sizes
// the cross-chain liquidation cap with borrowWithInterest(), which ignores borrows
// whose DESTINATION is the current chain. maxLiquidationAmount computes to 0, so the
// destination-chain check `require(repayAmount <= maxLiquidationAmount)` reverts every
// valid cross-chain liquidation, leaving underwater debt un-recoverable (liveness/DoS).
contract Finding58377Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_crossChainLiquidationBlocked() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("real cross-chain debt", e.realDebt());
        emit log_named_uint("miscalculated maxRepay cap", e.maxRepay());
        emit log_named_uint("blocked repay (harm magnitude at sink)", e.profit());

        // The cap for a real $1000 cross-chain debt is miscalculated to 0...
        assertEq(e.maxRepay(), 0, "cap should be miscalculated to zero");
        // ...so the valid $500 (50% close factor) liquidation is blocked.
        assertTrue(e.liquidationBlocked(), "valid liquidation must be blocked");
        // Harm magnitude (the blocked, un-recoverable liquidation) parked at SINK.
        assertEq(e.profit(), 500 ether, "harm magnitude must equal blocked repay");
        assertEq(MarkerToken(e.marker()).balanceOf(SINK), 500 ether, "sink balance mismatch");
    }
}
