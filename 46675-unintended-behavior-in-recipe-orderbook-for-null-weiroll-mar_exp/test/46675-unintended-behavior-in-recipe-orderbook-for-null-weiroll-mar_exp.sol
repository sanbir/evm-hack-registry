// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./46675-unintended-behavior-in-recipe-orderbook-for-null-weiroll-mar.sol";

contract Finding46675Test is Test {
    function test_null_market_moves_N() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.moved(), 1000 ether, "LP received 1000");
        assertEq(e.token().balanceOf(e.LP()), 1000 ether, "1000 moved to LP");
        assertEq(e.controlKept(), 1000 ether, "control kept the second 1000");
        emit log_named_uint("moved to LP", e.moved());
        emit log_named_uint("control kept", e.controlKept());
    }

    function test_control_zero_fill_reverts() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "filler still holds the control tranche");
    }
}
