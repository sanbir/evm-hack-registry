// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./41992-erc-6492-implementation-allows-draining-wallet-funds-by-mani.sol";

contract Finding41992Test is Test {
    function test_exploit_6492_side_effect_drains_10_weth() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.drained(), 10 ether, "drained 10");
        assertEq(e.weth().balanceOf(address(e)), 10 ether, "attacker");
        assertEq(e.weth().balanceOf(address(e.wallet())), 0, "wallet empty");
        assertTrue(e.manager().approved(), "approved");
    }

    function test_control_valid_owner_index_keeps_the_10_weth() public {
        Exploit e = new Exploit();
        e.runSafe();
        assertEq(e.weth().balanceOf(address(e.wallet())), 10 ether, "kept");
        assertEq(e.weth().balanceOf(address(e)), 0, "attacker empty");
        assertTrue(e.manager().approved(), "approved");
        assertFalse(e.manager().sideEffectCalled(), "no batch");
    }
}
