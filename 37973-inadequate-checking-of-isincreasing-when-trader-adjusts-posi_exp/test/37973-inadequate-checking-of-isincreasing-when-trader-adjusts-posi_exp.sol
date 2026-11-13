// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, Escrow, PerpEngineFixed} from
    "./37973-inadequate-checking-of-isincreasing-when-trader-adjusts-posi.sol";

contract Finding37973Test is Test {
    function test_exploit_flip_opens_a_short_while_the_market_is_disabled() public {
        Exploit e = new Exploit();
        e.run();

        assertFalse(e.increasing(), "treated as a decrease");
        assertEq(e.sizeAfter(), -2e18, "short of 2");
        assertEq(e.required(), 100 ether, "maintenance margin");
        assertEq(e.token().balanceOf(address(e.escrow())), 2000 ether, "2000 posted");
        assertLt(e.COLLATERAL(), 200 ether, "below initial margin");
    }

    function test_control_sign_flip_is_rejected_while_disabled() public {
        Token token = new Token();
        Escrow escrow = new Escrow(token);
        PerpEngineFixed engine = new PerpEngineFixed(token, escrow);
        engine.configure(1, false, false);
        engine.open(address(this), 1, 1, 1e18, 150 ether);
        token.mint(address(engine), 2000 ether);
        assertTrue(engine.isIncreasing(1, 1, -3e18), "flip is an increase");
        vm.expectRevert(bytes("market disabled"));
        engine.fillOrder(address(this), 1, 1, -3e18);
        int256 size = engine.positions(1, 1);
        assertEq(size, 1e18, "long unchanged");
        assertEq(token.balanceOf(address(escrow)), 0, "nothing posted");
        assertEq(token.balanceOf(address(engine)), 2000 ether, "lp funds stay");
    }
}
