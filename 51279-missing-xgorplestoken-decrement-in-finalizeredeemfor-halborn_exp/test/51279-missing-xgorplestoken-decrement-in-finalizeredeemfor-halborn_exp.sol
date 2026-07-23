// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./51279-missing-xgorplestoken-decrement-in-finalizeredeemfor-halborn.sol";

/*//////////////////////////////////////////////////////////////
    Gorples — missing xBorpaBalances decrement in finalizeRedeemFor (#51279)
//////////////////////////////////////////////////////////////*/
contract MissingDecrementTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        // User converted AMOUNT once but extracted 2*AMOUNT via double redeem.
        assertEq(e.gorples().balanceOf(address(e.user())), 2 * e.AMOUNT(), "double payout");
        // Inflated internal balance remains after the second finalize too.
        assertEq(e.xToken().xBorpaBalances(address(e.user())), e.AMOUNT(), "still inflated");
    }

    function test_finalizeRedeem_correctlyDecrements() public {
        // Control: the correct path (finalizeRedeem) zeros the balance.
        MockGorples g = new MockGorples();
        address system = makeAddr("system");
        XGorplesToken x = new XGorplesToken(g, system);
        address u = makeAddr("user");

        g.mint(u, 1000 ether);
        vm.startPrank(u);
        g.approve(address(x), 1000 ether);
        x.convert(1000 ether);
        x.redeem(1000 ether);
        x.finalizeRedeem(0);
        vm.stopPrank();

        assertEq(x.xBorpaBalances(u), 0, "correct path zeros balance");
        assertEq(g.balanceOf(u), 1000 ether, "user received payout");
    }
}
