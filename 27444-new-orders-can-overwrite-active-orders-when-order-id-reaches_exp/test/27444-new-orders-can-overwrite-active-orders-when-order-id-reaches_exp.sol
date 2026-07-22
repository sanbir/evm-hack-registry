// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27444-new-orders-can-overwrite-active-orders-when-order-id-reaches.sol";

contract DittoOrderIdReuseSelfLoopTest is Test {
    function test_NewOrdersOverwriteActiveOrdersAt65k() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.carolOrderId(), e.bobOrderId());
        assertEq(e.orderSlotOwnerAfter(), address(e.carol()));
        assertEq(e.bobEscrowedAfter(), 0);
    }

    /// @dev Control: WITHOUT the double-cancel corruption (a single normal
    ///      cancel, no cancelOrderFarFromOracle call on an already-cancelled
    ///      order), two sequential new orders get DISTINCT ids — proving the
    ///      collision only happens once the reuse chain is corrupted.
    function test_Control_NoCorruption_DistinctIds() public {
        MockToken token = new MockToken();
        OrderBook ob = new OrderBook(token);
        Actor eve = new Actor(token, ob);
        Actor bob = new Actor(token, ob);
        Actor carol = new Actor(token, ob);

        eve.deposit(10);
        uint16 eveId = eve.createOrder(10);
        eve.cancelOwn(eveId); // single, normal cancel - no double-processing

        bob.deposit(500);
        uint16 bobId = bob.createOrder(500); // legitimately reuses eve's id

        carol.deposit(777);
        uint16 carolId = carol.createOrder(777); // reuse chain is empty now - gets a FRESH id

        assertTrue(carolId != bobId, "carol collided with bob without the corruption - control invalid");

        (address bobSlotOwner,,,,) = ob.orders(bobId);
        assertEq(bobSlotOwner, address(bob), "bob's order survives intact without the corruption");
    }
}
