// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Sonic, Egg, EggsFixed} from "./46031-leveraged-positions-can-be-created-before-the-system-start-c.sol";

contract Finding46031Test is Test {
    function test_exploit_leverage_before_start_takes_the_floor() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.buyReverted(), "buy blocked");
        assertEq(e.attackerEggs(), 166666666666666666667, "floor size");
        assertEq(e.victimEggs(), 119047619047619047619, "victim short");
        assertEq(e.sonicOut(), 264864864864864864866, "sale");
        assertEq(e.profit(), 64864864864864864866, "profit");
        assertEq(e.egg().balanceOf(address(e.buyer())), 119047619047619047619, "victim eggs");
        assertEq(e.sonic().balanceOf(address(e.buyer())), 0, "victim spent the 200");
    }

    function test_control_guarded_leverage_reverts_before_start() public {
        Sonic sonic = new Sonic();
        Egg egg = new Egg();
        EggsFixed market = new EggsFixed(sonic, egg);
        vm.expectRevert(bytes("Trading must be initialized"));
        market.leverage(100 ether);
        market.setStart();
        market.leverage(100 ether);
        assertTrue(market.start(), "started");
    }
}
