// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    InvoiceManager,
    InvoiceManagerFixed,
    MiniToken,
    SmartWallet
} from "./62849-h-02-paid-tokens-by-smart-contract-wallets-are-not-refunded.sol";

contract PaidTokensNotRefundedTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant SESSION_KEY = 0x0000000000000000000000000000000000005151;
    address internal constant SOLVER = 0x0000000000000000000000000000000000050100;
    bytes32 internal constant BID_HASH = keccak256("bid-62849");

    uint256 internal constant EXPECTED_TOTAL = 100 ether;
    uint256 internal constant PARTIAL_PAID = 40 ether;

    function test_exploit_scwPartialPaymentLockedOnCancel() public {
        Exploit e = new Exploit();
        e.run();

        // --- HARM: the SCW paid PARTIAL_PAID in and lost all of it ---
        assertEq(e.buggyWalletDebited(), PARTIAL_PAID, "SCW debited its full partial payment");

        // The paid tokens physically remain stuck in InvoiceManager after cancel.
        assertEq(e.buggyImHeld(), PARTIAL_PAID, "partial payment locked in InvoiceManager");
        MiniToken token = MiniToken(e.tokenAddr());
        assertEq(token.balanceOf(e.imAddr()), PARTIAL_PAID, "real token balance stuck in InvoiceManager");
        assertEq(token.balanceOf(e.walletAddr()), 0, "SCW wallet balance drained to zero");

        // Settlement was permanently blocked (partial credit), forcing the cancel path.
        assertTrue(e.settleReverted(), "settle blocked for a partially-credited invoice");

        // cancelInvoice wiped ALL accounting (no refund record left for the SCW).
        assertFalse(e.buggyInvoiceExists(), "invoice accounting wiped by cancel, no refund");

        // Marker records the locked magnitude at the SINK.
        assertEq(e.strandedLocked(), PARTIAL_PAID, "stranded magnitude");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), PARTIAL_PAID, "marker records locked amount at SINK");

        // Prove there is NO SCW-refund exit: the invoice accounting is gone and the
        // paid tokens sit in InvoiceManager whose only mover (emergencyWithdraw)
        // sweeps to the admin, never back to the paying wallet.
        SmartWallet wallet = SmartWallet(e.walletAddr());
        assertEq(wallet.owner(), address(e), "wallet owned by exploit (SCW)");
        InvoiceManager im = InvoiceManager(e.imAddr());
        assertFalse(im.invoiceExists(SESSION_KEY), "no invoice remains to credit or settle against");
    }

    function test_control_fixedCancel_refundsScw() public {
        // Rebuild the identical scenario against the FIXED InvoiceManager, whose
        // cancelInvoice refunds credited amounts back to the stored smartWallet.
        MiniToken token = new MiniToken("USD Coin", "USDC");
        SmartWallet wallet = new SmartWallet(address(this));
        InvoiceManagerFixed im = new InvoiceManagerFixed(address(this), address(this));

        token.mint(address(wallet), PARTIAL_PAID);

        im.createInvoice(SESSION_KEY, address(wallet), SOLVER, BID_HASH, address(token), EXPECTED_TOTAL);

        // SCW partial claim.
        wallet.pay(address(token), address(im), PARTIAL_PAID);
        im.creditTokensToInvoice(SESSION_KEY, address(token), PARTIAL_PAID);

        assertEq(token.balanceOf(address(wallet)), 0, "SCW debited before cancel");
        assertEq(token.balanceOf(address(im)), PARTIAL_PAID, "tokens held pre-cancel");

        // Fixed cancel refunds the SCW.
        im.cancelInvoice(SESSION_KEY, "session expired; partial payment");

        assertEq(token.balanceOf(address(wallet)), PARTIAL_PAID, "FIX refunds SCW its partial payment");
        assertEq(token.balanceOf(address(im)), 0, "InvoiceManager holds nothing after refunding cancel");
        assertFalse(im.invoiceExists(SESSION_KEY), "invoice cleaned up");
    }
}
