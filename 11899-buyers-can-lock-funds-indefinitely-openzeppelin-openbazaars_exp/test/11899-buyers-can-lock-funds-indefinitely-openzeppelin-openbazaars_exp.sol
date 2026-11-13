// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Cash} from "./11899-buyers-can-lock-funds-indefinitely-openzeppelin-openbazaars.sol";

contract Finding11899Test is Test {
    function test_buyer_top_up_keeps_N_locked_and_control_releases() public {
        vm.warp(7200);
        Exploit e = new Exploit();
        e.run();

        Cash token = e.token();
        assertEq(e.controlReleased(), e.N(), "control");
        assertEq(token.balanceOf(address(e.seller())), e.N(), "seller");
        assertFalse(e.attackReleased(), "attack");
        assertEq(e.locked(), e.N() + e.DUST(), "locked");
        assertEq(token.balanceOf(address(e.escrow())), e.N() + e.DUST(), "escrow");

        console2.log("control released");
        console2.log(e.controlReleased());
        console2.log("attack released");
        console2.log(e.attackReleased() ? 1 : 0);
        console2.log("locked in escrow");
        console2.log(e.locked());
    }
}
