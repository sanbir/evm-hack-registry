// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import '@openzeppelin/contracts/interfaces/IERC165.sol';
import '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol';
import '@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol';

import './TreasureMarketplace.sol';

contract TreasureMarketplaceBuyer is ERC721Holder, ERC1155Holder {
    using SafeERC20 for IERC20;

    bytes4 private constant INTERFACE_ID_ERC721 = 0x80ac58cd;
    bytes4 private constant INTERFACE_ID_ERC1155 = 0xd9b67a26;

    TreasureMarketplace public marketplace;

    constructor(address _marketplace) {
        marketplace = TreasureMarketplace(_marketplace);
    }

    function buyItem(
        address _nftAddress,
        uint256 _tokenId,
        address _owner,
        uint256 _quantity,
        uint256 _pricePerItem
    ) external {
        (, uint256 pricePerItem,) = marketplace.listings(_nftAddress, _tokenId, _owner);

        require(pricePerItem == _pricePerItem, "pricePerItem changed!");

        // VULNERABILITY: Zero-quantity buy bypass in TreasureMarketplaceBuyer (convenience router)
        // ROOT CAUSE: No validation that _quantity > 0. The function blindly computes
        //   uint256 totalPrice = _pricePerItem * _quantity;   // <-- 0 when _quantity==0
        // then does safeTransferFrom(0) + safeApprove(0) + delegates _quantity=0 to marketplace.buyItem.
        // After receiving the asset (via the marketplace hop), it ALWAYS forwards the ERC721/ERC1155 to msg.sender
        //   regardless of whether totalPrice was zero or whether _quantity matched the transfer.
        // CODE REF: L33 (price check), L43 (mul), L44-45 (0-value xfers), L47 (delegate), L49-53 (forward).
        // WHY IT EXISTS: The buyer was a thin wrapper (probably for UX/approval bundling). _quantity was modeled after
        //   ERC1155 multi-token semantics, but the wrapper never enforced the positive-quantity invariant that
        //   createListing imposes (marketplace L134: require(_quantity > 0, "nothing to list")).
        //   No access control; callable by anyone.
        // IMPACT: Any whitelisted ERC721 (or ERC1155 with qty>=0) listed on the marketplace can be purchased for
        //   literally 0 MAGIC. Seller receives nothing (see marketplace._buyItem). The listing is not cleaned up
        //   for ERC721 because qty -= 0 leaves it in storage (and ownerOf has changed, making it un-cancelable).
        //   This was the exact vector used in the 2022-03 TreasureDAO incident.
        // EXPLOIT STEPS (via this contract):
        // 1. Attacker calls buyer.buyItem(nft, tokenId, currentOwner, 0, listedPricePerItem)
        // 2. Buyer reads the on-chain listing price, the require passes because attacker supplies the real price.
        // 3. totalPrice=...*0 == 0; 0-value transfer/approve to buyer; buyer calls marketplace.buyItem(...,0)
        // 4. (marketplace executes the zero-cost transfer of the ERC721 to the buyer contract)
        // 5. Buyer forwards via safeTransferFrom(buyer, attacker, tokenId)
        // 6. Attacker's onERC721Received receives the NFT for free.
        uint256 totalPrice = _pricePerItem * _quantity;
        IERC20(marketplace.paymentToken()).safeTransferFrom(msg.sender, address(this), totalPrice);
        IERC20(marketplace.paymentToken()).safeApprove(address(marketplace), totalPrice);

        marketplace.buyItem(_nftAddress, _tokenId, _owner, _quantity);

        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721(_nftAddress).safeTransferFrom(address(this), msg.sender, _tokenId);
        } else {
            IERC1155(_nftAddress).safeTransferFrom(address(this), msg.sender, _tokenId, _quantity, bytes(""));
        }
    }

    // just in case there's anything stuck here

    function withdraw() external {
        IERC20 token = IERC20(marketplace.paymentToken());
        token.safeTransferFrom(address(this), marketplace.owner(), token.balanceOf(address(this)));
    }

    function withdrawNFT(address _nftAddress, uint256 _tokenId, uint256 _quantity) external {
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721(_nftAddress).safeTransferFrom(address(this), marketplace.owner(), _tokenId);
        } else {
            IERC1155(_nftAddress).safeTransferFrom(address(this), marketplace.owner(), _tokenId, _quantity, bytes(""));
        }
    }
}
