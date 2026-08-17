// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, GNSTrading, Vault, MiniToken, MarkerToken} from "./58128-h-01-holding-fees-accounting-discrepancy-when-collateral-is.sol";

// Gains Network H-01 (finding 58128): realizeHoldingFeesOnOpenTrade caps the
// collateral sent to the vault to what's available, but records the FULL
// holding fee as realized. A 500x/1 ETH position accrues 1.5 ETH of fees; only
// 1 ETH is sent to the vault while 1.5 ETH is recorded. After a 1 ETH top-up
// and close, the unsent 0.5 ETH stays stuck in the diamond and the vault
// permanently loses it.
contract Finding58128Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_holdingFeeDiscrepancy_vaultUnderCollects() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("recorded realized fees", e.recordedRealized());
        emit log_named_uint("actually sent to vault", e.vaultReceived());
        emit log_named_uint("vault shortfall", e.shortfall());
        emit log_named_uint("stuck in diamond", e.stuckInDiamond());
        emit log_named_uint("trader refund", e.traderRefund());

        // full fee recorded, only available collateral transferred
        assertEq(e.recordedRealized(), 1.5 ether, "should record full 1.5 ETH fee");
        assertEq(e.vaultReceived(), 1 ether, "vault only receives the available 1 ETH");

        // the vault is shorted exactly the amount left stranded in the diamond
        assertEq(e.shortfall(), 0.5 ether, "vault under-collected 0.5 ETH");
        assertEq(e.stuckInDiamond(), e.shortfall(), "shortfall stuck in diamond");
        assertEq(e.traderRefund(), 0.5 ether, "trader gets fair 0.5 ETH back");

        // vault's permanent loss quantified at SINK
        assertEq(e.marker().balanceOf(SINK), 0.5 ether, "0.5 ETH loss marked at SINK");
    }
}
