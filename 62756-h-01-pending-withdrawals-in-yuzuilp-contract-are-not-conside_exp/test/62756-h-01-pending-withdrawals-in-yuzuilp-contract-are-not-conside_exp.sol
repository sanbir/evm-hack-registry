// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, YuzuOrderBook, YuzuOrderBookFixed, MiniToken} from
    "./62756-h-01-pending-withdrawals-in-yuzuilp-contract-are-not-conside.sol";

contract PendingWithdrawalYieldLeakTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant WITHDRAWER = 0x000000000000000000000000000000000000aaaa;
    address internal constant REMAINING = 0x000000000000000000000000000000000000BbBB;

    uint256 internal constant DEPOSIT = 100 ether;

    /// @notice Buggy path: the withdrawer is paid the stale pre-yield amount and
    ///         the pending-window yield their still-participating shares earned
    ///         leaks to the remaining holder.
    function test_exploit_pendingWithdrawalLosesYield() public {
        Exploit e = new Exploit();
        e.run();

        // A is paid only the fixed pre-yield 100, though the fair pro-rata is 150.
        assertEq(e.withdrawerPayout(), 100 ether, "withdrawer paid stale pre-yield amount");
        assertEq(e.withdrawerFair(), 150 ether, "withdrawer fair pro-rata (principal + pending-window yield)");
        assertLt(e.withdrawerPayout(), e.withdrawerFair(), "withdrawer received less than entitled");

        // The 50 shortfall leaks to B: B's redeemable rose to 200 (fair was 150).
        assertEq(e.remainingRedeemableBuggy(), 200 ether, "remaining holder's redeemable windfall");
        assertEq(e.lostYield(), 50 ether, "lost-yield magnitude");

        // The 50e18 LOST-YIELD is recorded on the marker at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 50 ether, "marker records LOST-YIELD at SINK");
        assertEq(e.sinkMarkerBalance(), 50 ether, "sink marker balance");

        // Real underlying really left behind: the vault still holds the withdrawer's
        // 50 of yield (paid A only 100 out of the 300 present at finalize).
        MiniToken assetToken = MiniToken(e.assetAddr());
        assertEq(assetToken.balanceOf(WITHDRAWER), 100 ether, "withdrawer only got principal-priced amount");
        assertEq(assetToken.balanceOf(e.vaultAddr()), 200 ether, "vault retains the leaked yield for B");
    }

    /// @notice Negative control: the fixed vault honors the still-participating
    ///         shares at the finalize-time price, so the withdrawer gets the full
    ///         pro-rata 150 and the remaining holder keeps only its fair 150.
    function test_control_fixedFinalize_paysFullProRata() public {
        MiniToken assetToken = new MiniToken("Yuzu USD", "yUSD");
        YuzuOrderBookFixed vault = new YuzuOrderBookFixed(address(assetToken));

        assetToken.mint(address(this), DEPOSIT * 2);
        assetToken.approve(address(vault), type(uint256).max);

        vault.deposit(DEPOSIT, WITHDRAWER); // A: 100 shares
        vault.deposit(DEPOSIT, REMAINING); // B: 100 shares

        (uint256 orderId, uint256 fixedAssets) = vault.createRedeemOrder(100 ether, WITHDRAWER, WITHDRAWER);
        assertEq(fixedAssets, 100 ether, "value recorded at creation");

        assetToken.mint(address(vault), 100 ether); // yield accrues

        uint256 payout = vault.finalizeRedeem(orderId);

        // Withdrawer receives full pro-rata; no yield leaks to the remaining holder.
        assertEq(payout, 150 ether, "fixed vault pays full pro-rata");
        assertEq(assetToken.balanceOf(WITHDRAWER), 150 ether, "withdrawer made whole");
        uint256 bRedeemable = vault.convertToAssets(vault.balanceOf(REMAINING));
        assertEq(bRedeemable, 150 ether, "remaining holder keeps only its fair share");
    }
}
