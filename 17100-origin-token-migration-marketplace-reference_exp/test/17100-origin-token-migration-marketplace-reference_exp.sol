// SPDX-License-Identifier: MIT
pragma solidity ^0.4.24;

// Real-source PoC for AuditVault #17100 (Origin Protocol).
// Deploys the audited OriginToken, TokenMigration and V00_Marketplace verbatim
// (OriginProtocol/origin @ 981e580fa3ba9325e10eb0608fe6aeb4605e7a23) and proves
// that migrating/pausing the OGN token permanently traps the Marketplace escrow:
// finalize() AND withdrawListing() both revert because the Marketplace still
// references the paused old token. forge-std is NOT usable at 0.4.x, so this is a
// cheatcode-free `test_`-prefixed contract (forge treats it as a test contract).
import {OriginToken} from "../src/contracts/token/OriginToken.sol";
import {TokenMigration} from "../src/contracts/token/TokenMigration.sol";
import {V00_Marketplace} from "../src/contracts/marketplace/v00/Marketplace.sol";

contract PoC_17100 {
    function test_migrationLeavesMarketplacePointingAtPausedToken() public {
        uint256 deposit = 10 ether;
        uint256 offerValue = 20 ether;
        uint256 supply = deposit + offerValue; // 30 OGN

        // Audited OriginToken + audited V00_Marketplace pointing at it. The full
        // supply is minted to this test account so the real ERC20 escrow calls run.
        OriginToken oldToken = new OriginToken(supply);
        OriginToken newToken = new OriginToken(0);
        V00_Marketplace marketplace = new V00_Marketplace(address(oldToken));

        // Escrow a 10-OGN listing deposit and an accepted 20-OGN offer, both
        // denominated in the old token. Marketplace now custodies all 30 OGN.
        oldToken.approve(address(marketplace), supply);
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
        require(oldToken.balanceOf(address(marketplace)) == supply, "escrow not funded");

        // Audited TokenMigration mints replacement OGN to every holder and the old
        // token is paused. The Marketplace is a holder, so its 30-OGN escrow is
        // "migrated" into newToken, but the audited Marketplace still stores the
        // OLD token address in tokenAddr and in every Offer.currency.
        TokenMigration migration = new TokenMigration(oldToken, newToken);
        newToken.transferOwnership(address(migration));
        oldToken.pause();
        migration.migrateAccount(address(marketplace));
        migration.finish(address(this));

        require(oldToken.paused(), "old token was not paused");
        require(
            newToken.balanceOf(address(marketplace)) == supply,
            "replacement balance was not migrated"
        );
        require(
            marketplace.tokenAddr() == address(oldToken),
            "marketplace token reference changed"
        );

        // Harm #1: finalize() -> paySeller() calls Offer.currency.transfer() on the
        // paused old token, so the settlement reverts and the offer escrow is stuck.
        (bool finalized, ) = address(marketplace).call(
            abi.encodeWithSignature(
                "finalize(uint256,uint256,bytes32)",
                0,
                0,
                bytes32("finalize")
            )
        );
        require(!finalized, "finalize unexpectedly used the migrated token");

        // Harm #2: withdrawListing() also transfers via the paused old token, so the
        // seller cannot even reclaim the listing deposit.
        (bool withdrawn, ) = address(marketplace).call(
            abi.encodeWithSignature(
                "withdrawListing(uint256,address,bytes32)",
                0,
                address(this),
                bytes32("withdraw")
            )
        );
        require(!withdrawn, "withdrawListing unexpectedly used the migrated token");

        // Both escrows remain locked in the Marketplace; the replacement newToken
        // balance sits there unusable (Marketplace has no code path to spend it).
        require(
            oldToken.balanceOf(address(marketplace)) == supply,
            "old-token escrow was released"
        );
        require(
            newToken.balanceOf(address(marketplace)) == supply,
            "replacement escrow was consumed"
        );

        (, uint256 listingDeposit, ) = marketplace.listings(0);
        require(listingDeposit == deposit, "listing deposit was lost");
    }
}
