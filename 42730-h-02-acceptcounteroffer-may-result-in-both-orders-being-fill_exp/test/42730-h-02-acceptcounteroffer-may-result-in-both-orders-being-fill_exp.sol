// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./42730-h-02-acceptcounteroffer-may-result-in-both-orders-being-fill.sol";

contract PuttyDoubleFillTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.putty().filledCount(), 2, "both orders filled");
        assertEq(e.token().balanceOf(address(e.putty())), 200e18, "double collateral");
    }

    function test_control_cancel_after_fill_does_not_revert() public {
        MockERC20 token = new MockERC20();
        PuttyV2 putty = new PuttyV2();
        token.mint(address(this), 100e18);
        token.approve(address(putty), type(uint256).max);

        PuttyV2.Order memory order =
            PuttyV2.Order({maker: address(this), baseAsset: address(token), baseAmount: 100e18, isCall: true});

        putty.fillOrder(order);
        // cancel does not revert — the bug surface
        putty.cancel(order);
        assertTrue(putty.cancelledOrders(putty.hashOrder(order)));
        assertTrue(putty.isFilled(putty.hashOrder(order)));
    }
}
