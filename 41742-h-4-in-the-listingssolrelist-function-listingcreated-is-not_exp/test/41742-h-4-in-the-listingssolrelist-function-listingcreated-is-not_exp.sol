// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, FloorToken, ListingsFixed, ShutdownFixed} from
    "./41742-h-4-in-the-listingssolrelist-function-listingcreated-is-not.sol";

contract Finding41742Test is Test {
    function test_exploit_future_created_blocks_shutdown() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.storedCreated(), uint40(type(uint32).max), "created");
        assertTrue(e.executeReverted(), "reverted");
        assertEq(e.token().balanceOf(address(e.shutdown())), 1000 ether, "locked");
    }

    function test_control_timestamp_created_pays_the_escrow() public {
        FloorToken token = new FloorToken();
        ListingsFixed listings = new ListingsFixed();
        ShutdownFixed shutdown = new ShutdownFixed(token, listings);
        token.mint(address(this), 1000 ether);
        listings.seed(1, address(0xB0B));
        token.transfer(address(shutdown), 1000 ether);
        listings.relist(1, ListingsFixed.Listing({owner: address(this), created: uint40(type(uint32).max), duration: 30 days}));
        assertEq(listings.get(1).created, uint40(block.timestamp), "stamped now");
        uint256 paid = shutdown.execute();
        assertEq(paid, 1000 ether, "paid");
        assertEq(token.balanceOf(address(this)), 1000 ether, "recovered");
        assertEq(token.balanceOf(address(shutdown)), 0, "escrow empty");
    }
}
