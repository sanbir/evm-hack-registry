// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27443-users-lose-funds-and-market-functionality-breaks-when-market.sol";

contract DittoCancelFarFromOracleTest is Test {
    function test_UsersLoseFundsWhenMarketReaches65k() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.bobEscrowedAfterCancel(), 0);
        assertEq(e.obLockedBalance(), 1000);
    }

    /// @dev Control: a NORMAL, owner-only cancel (cancelBid) correctly
    ///      refunds the escrow before unlinking — proving the bug is
    ///      specifically that cancelOrderFarFromOracle skips that refund,
    ///      not that refunds never work at all.
    function test_Control_NormalCancelBid_Refunds() public {
        MockToken token = new MockToken();
        OrderBook ob = new OrderBook(token);
        Actor bob = new Actor(token, ob);

        bob.deposit(1000);
        uint16 id = bob.createBid(1000);
        assertEq(ob.escrowed(address(bob)), 0);

        vm.prank(address(bob));
        ob.cancelBid(id);

        assertEq(ob.escrowed(address(bob)), 1000, "normal cancelBid must refund the escrow");
        bob.withdraw(1000);
        assertEq(token.balanceOf(address(bob)), 1000);
    }

    /// @dev Control: cancelOrderFarFromOracle correctly reverts while the
    ///      orderId counter is below the 65000 threshold.
    function test_Control_BelowThreshold_Reverts() public {
        MockToken token = new MockToken();
        OrderBook ob = new OrderBook(token);
        Actor bob = new Actor(token, ob);

        bob.deposit(1000);
        uint16 id = bob.createBid(1000);

        vm.expectRevert();
        ob.cancelOrderFarFromOracle(id, 1);
    }
}
