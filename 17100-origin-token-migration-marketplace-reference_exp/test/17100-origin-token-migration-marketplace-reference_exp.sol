// SPDX-License-Identifier: MIT
pragma solidity ^0.4.24;

import {OriginToken} from "../src/contracts/token/OriginToken.sol";
import {TokenMigration} from "../src/contracts/token/TokenMigration.sol";
import {V00_Marketplace} from "../src/contracts/marketplace/v00/Marketplace.sol";

contract PoC_17100 {
    function test_migrationLeavesMarketplacePointingAtPausedToken() public {
        uint256 deposit = 10 ether;
        uint256 offerValue = 20 ether;

        // These are the audited OriginToken and TokenMigration contracts. The
        // initial supply is deliberately held by this test account so the
        // audited Marketplace can escrow it through its real ERC20 calls.
        OriginToken oldToken = new OriginToken(deposit + offerValue);
        OriginToken newToken = new OriginToken(0);
        V00_Marketplace marketplace = new V00_Marketplace(address(oldToken));

        oldToken.approve(address(marketplace), deposit + offerValue);
        marketplace.createListing(bytes32("listing"), deposit, address(this));

        (bool offered, ) = address(marketplace).call(
            abi.encodeWithSignature(
                "makeOffer(uint256,bytes32,uint256,address,uint256,uint256,address,address)",
                0,
                bytes32("offer"),
                0,
                address(0),
                0,
                offerValue,
                address(oldToken),
                address(this)
            )
        );
        require(offered, "offer creation failed");
        marketplace.acceptOffer(0, 0, bytes32("accept"));

        // TokenMigration mints the replacement balance to each holder, while
        // the old OriginToken is paused. The Marketplace is a holder, so its
        // escrow is migrated, but the audited Marketplace still stores the
        // old token address in tokenAddr and in Offer.currency.
        TokenMigration migration = new TokenMigration(oldToken, newToken);
        newToken.transferOwnership(address(migration));
        oldToken.pause();
        migration.migrateAccount(address(marketplace));
        migration.finish(address(this));

        require(oldToken.paused(), "old token was not paused");
        require(
            newToken.balanceOf(address(marketplace)) == deposit + offerValue,
            "replacement balance was not migrated"
        );
        require(
            marketplace.tokenAddr() == address(oldToken),
            "marketplace token reference changed"
        );

        // V00_Marketplace.finalize() calls Offer.currency.transfer(). That is
        // still oldToken, so the paused token rejects the settlement and the
        // transaction rolls back; no replacement-token balance is consumed.
        (bool finalized, ) = address(marketplace).call(
            abi.encodeWithSignature(
                "finalize(uint256,uint256,bytes32)",
                0,
                0,
                bytes32("finalize")
            )
        );
        require(!finalized, "finalize unexpectedly used the migrated token");
        require(
            oldToken.balanceOf(address(marketplace)) == deposit + offerValue,
            "old-token escrow was released"
        );
        require(
            newToken.balanceOf(address(marketplace)) == deposit + offerValue,
            "replacement escrow was consumed"
        );

        (, uint256 listingDeposit, ) = marketplace.listings(0);
        require(listingDeposit == deposit, "listing deposit was lost");
    }
}
