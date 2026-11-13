// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Ct, ProtectedListingsFixed} from
    "./41762-h-24-incorrect-index-handling-in-checkpoint-creation-leads-t.sol";

contract Finding41762Test is Test {
    function test_exploit_second_listing_checkpoint_locks_one_ct() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.firstIndex(), 0, "first index");
        assertEq(e.secondIndex(), 1, "second index");
        assertEq(e.lengthAfter(), 1, "only one checkpoint");
        assertEq(e.unlocked(), 1 ether, "first listing returned");
        assertTrue(e.secondReverted(), "second unlock reverted");
        assertEq(e.ct().balanceOf(address(e.listings())), 1 ether, "1 CT stuck");
    }

    function test_control_same_timestamp_returns_the_existing_index() public {
        Ct ct = new Ct();
        ProtectedListingsFixed listings = new ProtectedListingsFixed(ct);
        ct.mint(address(this), 2 ether);
        ct.approve(address(listings), 2 ether);
        address collection = address(0xC011EC);

        ProtectedListingsFixed.CreateListing[] memory batch = new ProtectedListingsFixed.CreateListing[](2);
        batch[0] = ProtectedListingsFixed.CreateListing(collection, 1, 1 ether);
        batch[1] = ProtectedListingsFixed.CreateListing(collection, 2, 1 ether);
        listings.createListings(batch);

        uint256 first = listings.unlock(collection, 1);
        uint256 second = listings.unlock(collection, 2);

        assertEq(first, 1 ether, "first returned");
        assertEq(second, 1 ether, "second returned");
        assertEq(ct.balanceOf(address(listings)), 0, "nothing stuck");
        assertEq(ct.balanceOf(address(this)), 2 ether, "both deposits back");
    }
}
