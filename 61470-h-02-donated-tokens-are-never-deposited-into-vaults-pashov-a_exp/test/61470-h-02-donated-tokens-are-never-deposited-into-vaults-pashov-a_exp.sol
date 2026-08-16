// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, HyperEvmVault, VaultEscrow, MiniToken, MarkerToken} from "./61470-h-02-donated-tokens-are-never-deposited-into-vaults-pashov-a.sol";

// Blueberry H-02 (finding 61470): HyperEvmVault._totalEscrowValue counts
// escrow.tvl() = vaultEquity + raw assetBalance. Donated tokens inflate the raw
// balance (and thus share price) but are never pushed into the L1 vault, so
// VaultEscrow.withdraw's `require(vaultEquity_ >= lastWithdraws)` reverts on the
// donation-inflated portion. An honest depositor's redemption always reverts;
// the donated tokens are locked forever.
contract Finding61470Test is Test {
    address internal constant SINK = address(0x000000000000000000000000000000000000D00d);

    function test_exploit_donationLocksHonestRedemption() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("honest shares still held (un-redeemable)", e.honestSharesStillHeld());
        emit log_named_uint("donated tokens stuck in escrow", e.donatedStuckInEscrow());
        emit log_named_uint("harm realized at sink", e.stuckAtSink());

        // honest user minted 100 shares against the donation-inflated price
        assertEq(e.honestSharesStillHeld(), 100, "honest user holds 100 shares");
        // their redemption reverts (DoS) -> shares remain un-redeemable
        assertTrue(e.honestRedeemReverted(), "honest redemption should revert");
        // the donated tokens are locked in the escrow, never withdrawable
        assertEq(e.donatedStuckInEscrow(), 100, "100 donated tokens locked in escrow");
        // DoS/locked-funds harm magnitude (honest user's 200 stuck assets) at SINK
        MarkerToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), 200 ether, "harm magnitude 200e18 realized at sink");
    }
}
