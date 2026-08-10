// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    AccountableAsyncRedeemVault,
    AccountableAsyncRedeemVaultFixed,
    AccountableAsyncRedeemVaultBase,
    MiniToken
} from "./62972-accountableasyncredeemvaultfulfillredeemrequest-ignores-proc.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Accountable finding 62972 — AccountableAsyncRedeemVault::fulfillRedeemRequest
// ignores processingMode and settles a RequestPrice redeem at the CURRENT share
// price instead of the price LOCKED at request time. When the price falls before
// fulfilment, the redeemer receives fewer assets than the RequestPrice guarantee
// promised and the shortfall stays retained in the vault.
// ─────────────────────────────────────────────────────────────────────────────
contract Finding62972Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_fulfillUsesCurrentPrice_shortsRequestPriceRedeemer() public {
        Exploit e = new Exploit();
        e.run();

        // RequestPrice guaranteed 100 assets (100 shares locked at price 1e18).
        assertEq(e.guaranteedAssets(), 100e18, "RequestPrice guarantee");

        // The buggy fulfilment settled at the CURRENT 0.5e18 -> only 50 assets paid.
        assertEq(e.receivedAssets(), 50e18, "redeemer received current-price amount");
        assertLt(e.receivedAssets(), e.guaranteedAssets(), "redeemer shorted vs guarantee");

        // The 50-asset shortfall is retained by the vault (accrues to other holders).
        assertEq(e.shortfall(), 50e18, "shortfall magnitude");
        assertEq(e.strandedInVault(), 50e18, "shortfall retained in the vault");

        // Real assets: redeemer holds only 50; the vault still holds the other 50.
        MiniToken asset = MiniToken(e.assetAddr());
        assertEq(asset.balanceOf(e.vaultAddr()), 50e18, "vault retains the shorted 50");

        // Harm recorded on the marker token to the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 50e18, "marker records the 50-asset shortfall at SINK");
        assertEq(e.sinkMarkerBalance(), 50e18, "exposed sink marker balance");
    }

    // Negative control: the recommended fix settles RequestPrice redeems at the
    // STORED request price, so the same sequence pays the full 100 assets and
    // strands nothing — proving the harm is caused solely by the wrong price source.
    function test_control_fixedUsesStoredRequestPrice_paysFullGuarantee() public {
        MiniToken asset = new MiniToken("Vault Asset", "AST");
        AccountableAsyncRedeemVaultFixed vault =
            new AccountableAsyncRedeemVaultFixed(address(asset), address(this));

        // Back the redemption with the full guaranteed 100 assets.
        asset.mint(address(vault), 100e18);

        vault.setProcessingMode(AccountableAsyncRedeemVaultBase.ProcessingMode.RequestPrice);
        vault.setSharePrice(1e18);

        // Lock a redeem at price 1e18 (guarantee 100 assets).
        vault.requestRedeem(100e18);
        assertEq(vault.requestSharePrice(address(this)), 1e18, "request price locked at 1e18");

        // Price falls before fulfilment.
        vault.setSharePrice(5e17);

        // Fixed path settles at the STORED 1e18, not the current 0.5e18.
        vault.fulfillRedeemRequest(address(this), 100e18);
        uint256 got = vault.claim();

        assertEq(got, 100e18, "fix pays the full RequestPrice guarantee");
        assertEq(asset.balanceOf(address(this)), 100e18, "redeemer received full 100 assets");
        assertEq(asset.balanceOf(address(vault)), 0, "no shortfall retained under the fix");
    }
}
